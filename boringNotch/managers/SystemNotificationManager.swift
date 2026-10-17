//
//  SystemNotificationManager.swift
//  boringNotch
//
import AppKit
import Combine
import Defaults
import UserNotifications

enum NotificationPriority: String {
    case passive, normal, high
}

struct SystemNotification: Identifiable, Equatable {
    let id: String
    let appName: String?
    let bundleID: String?
    let title: String?
    let subtitle: String?
    let body: String?
    let receivedAt: Date
    /// First eight hex digits of the notification's UUID, when known.
    var recordUUID: String?
    /// Shown the moment the notification arrived, before its text is known.
    var isPlaceholder = false
    var priority: NotificationPriority = .normal
}

@MainActor
final class SystemNotificationManager: ObservableObject {
    static let shared = SystemNotificationManager()

    @Published private(set) var activeNotification: SystemNotification?
    @Published private(set) var queuedNotifications: [SystemNotification] = []

    private let queueLimit = 5
    private var displayDuration: TimeInterval { Defaults[.notificationDisplayDuration] }
    private var dismissTask: Task<Void, Never>?
    private var notificationObserver: NSObjectProtocol?
    private var isUserPresent = false
    private var recentKeys: [String: Date] = [:]
    private var earlyObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var watchdogTask: Task<Void, Never>?
    private var isEnsuringServices = false

    /// When each source last delivered something, for the settings status panel.
    @Published private(set) var lastBannerAt: Date?
    @Published private(set) var lastDatabaseAt: Date?
    @Published private(set) var lastEarlyAt: Date?
    /// Whether the most recent dismissal was the user's (close button, or
    /// opening the app) rather than the notification expiring.
    private(set) var lastDismissByUser = false
    /// Placeholder id by notification UUID, so the real text can replace it in place.
    private var placeholderIDs: [String: String] = [:]
    /// UUIDs of placeholders the user closed: their text must not pop back up.
    private var dismissedPlaceholders = Set<String>()
    /// Lower-priority notifications that arrived while a high-priority one was
    /// on screen; they follow it instead of pushing it off.
    private var heldBehindHigh: [SystemNotification] = []
    private static let heldLimit = 3
    private var recentArrivals: [(date: Date, bundleID: String?, appName: String?)] = []

    private init() {
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .systemNotificationDidAppear, object: nil, queue: .main
        ) { [weak self] note in
            guard let payload = note.userInfo as? [String: String] else { return }
            Task { @MainActor in self?.add(payload) }
        }
        earlyObserver = NotificationCenter.default.addObserver(
            forName: .systemNotificationEarlySignal, object: nil, queue: .main
        ) { [weak self] note in
            guard let payload = note.userInfo as? [String: String] else { return }
            Task { @MainActor in self?.handleEarlySignal(payload) }
        }
    }

    deinit {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
        if let earlyObserver {
            NotificationCenter.default.removeObserver(earlyObserver)
        }
    }

    func start() async {
        startWatchdog()
        updateDatabaseWatcher()
        guard await XPCHelperClient.shared.isAccessibilityAuthorized() else { return }
        updateFilter()
        _ = await XPCHelperClient.shared.startNotificationWatching()
    }

    // MARK: Keeping the helper's services alive

    /// The helper process can be restarted by the system, most often around
    /// sleep, and takes the banner reader and the early signal with it. Check
    /// after wake, after a dropped connection, and every half minute.
    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                await self?.ensureServices(restartBanner: true)
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: .xpcHelperInterrupted, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                await self?.ensureServices()
            }
        }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.ensureServices()
            }
        }
    }

    /// Starts whatever should be running in the helper but is not. With
    /// `restartBanner` the banner reader is restarted even when it looks fine
    /// (after wake its Accessibility observer may have gone stale).
    func ensureServices(restartBanner: Bool = false) async {
        guard !isEnsuringServices, Defaults[.notificationLiveActivity] else { return }
        isEnsuringServices = true
        defer { isEnsuringServices = false }

        updateDatabaseWatcher()
        guard let status = await XPCHelperClient.shared.serviceStatus() else { return }

        let trusted = status["axTrusted"]?.boolValue == true
        let running = status["bannerRunning"]?.boolValue == true
        let attached = status["bannerPID"]?.intValue ?? 0
        let current = status["notificationCenterPID"]?.intValue ?? 0
        let stale = running && current != 0 && attached != current
        guard trusted, !running || stale || restartBanner else { return }

        if running {
            XPCHelperClient.shared.stopNotificationWatching()
            try? await Task.sleep(for: .milliseconds(400))
        }
        updateFilter()
        _ = await XPCHelperClient.shared.startNotificationWatching()
    }

    func updateDatabaseWatcher() {
        if Defaults[.notificationLiveActivity], Defaults[.notificationFromDatabase] {
            NotificationDatabaseWatcher.shared.start()
        } else {
            NotificationDatabaseWatcher.shared.stop()
        }
        // The early signal only makes sense with the database as the source
        // of the text that replaces the placeholder.
        if Defaults[.notificationLiveActivity], Defaults[.notificationFromDatabase],
           Defaults[.notificationEarlyPlaceholder] {
            Task { _ = await XPCHelperClient.shared.startEarlyNotificationSignal() }
        } else {
            XPCHelperClient.shared.stopEarlyNotificationSignal()
        }
    }

    func stop() {
        NotificationDatabaseWatcher.shared.stop()
        XPCHelperClient.shared.stopEarlyNotificationSignal()
        XPCHelperClient.shared.stopNotificationWatching()
        queuedNotifications.removeAll()
        heldBehindHigh.removeAll()
        isUserPresent = false
        dismissActive()
    }

    func holdActive() {
        isUserPresent = true
        dismissTask?.cancel()
        dismissTask = nil
    }

    func resumeDismiss(after delay: TimeInterval = 2) {
        isUserPresent = false
        queuedNotifications.removeAll()
        guard let notification = activeNotification else { return }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.dismissActive(token: notification.id, byUser: false)
        }
    }

    func dismissActive(token: String? = nil, byUser: Bool = true) {
        guard token == nil || activeNotification?.id == token else { return }
        if let closing = activeNotification, closing.isPlaceholder, let uuid = closing.recordUUID {
            placeholderIDs[uuid] = nil
            if byUser { dismissedPlaceholders.insert(uuid) }
        }
        dismissTask?.cancel()
        dismissTask = nil
        lastDismissByUser = byUser
        activeNotification = nil
        if isUserPresent {
            promoteNext()
        } else {
            queuedNotifications.removeAll()
        }
        if activeNotification == nil, !heldBehindHigh.isEmpty {
            show(heldBehindHigh.removeFirst())
        }
    }

    func showNextQueued() {
        guard isUserPresent, let next = queuedNotifications.first else { return }
        if let activeNotification {
            queuedNotifications.append(activeNotification)
        }
        queuedNotifications.removeFirst()
        show(next)
    }

    func open(_ notification: SystemNotification) async -> Bool {
        let workspace = NSWorkspace.shared

        // A notification read from its banner can be clicked for real: the
        // app then opens the conversation, message or event itself.
        let id = notification.id
        if !id.hasPrefix("db-"), !id.hasPrefix("early-"), !id.hasPrefix("test-"),
           await XPCHelperClient.shared.pressNotification(token: id) {
            return true
        }

        for bundleID in candidateBundleIDs(for: notification) {
            let running = workspace.runningApplications.first { application in
                guard !application.isTerminated,
                      let applicationBundleID = application.bundleIdentifier else { return false }
                return normalizeBundleIdentifier(applicationBundleID) == bundleID
            }

            if let running {
                if running.activate(options: [.activateAllWindows]) {
                    return true
                }
                if let appURL = running.bundleURL,
                   await launchApplication(at: appURL) {
                    return true
                }
            }

            if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID),
               await launchApplication(at: appURL) {
                return true
            }
        }

        return false
    }

    private func add(_ payload: [String: String]) {
        guard let token = payload["token"], !token.isEmpty else { return }
        if token.hasPrefix("db-") { lastDatabaseAt = Date() } else { lastBannerAt = Date() }
        let appName = nonEmpty(payload["appName"])
        var bundleID = nonEmpty(payload["bundleID"]).map {
            normalizeBundleIdentifier($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // The helper only has the banner's display name and can miss when the
        // source is a helper process or is no longer running. Re-resolve here
        // so both the icon and launch action get the real application.
        if bundleID.map(isLaunchable) != true,
           let appName,
           let resolved = BundleIDResolver.shared.bundleID(forAppNamed: appName) {
            let resolved = normalizeBundleIdentifier(resolved)
            bundleID = resolved
        }

        let notification = SystemNotification(
            id: token,
            appName: appName,
            bundleID: bundleID,
            title: nonEmpty(payload["title"]),
            subtitle: nonEmpty(payload["subtitle"]),
            body: nonEmpty(payload["body"]),
            receivedAt: Date(),
            priority: NotificationPriority(rawValue: payload["priority"] ?? "") ?? .normal
        )
        // Test notifications from the settings page ignore the app filter.
        guard token.hasPrefix("test-") || isAllowed(notification) else { return }
        noteArrival(notification)

        // The text for a notification already on screen as a placeholder.
        if let uuid = nonEmpty(payload["recordUUID"]) {
            if dismissedPlaceholders.remove(uuid) != nil { return }
            if let placeholderID = placeholderIDs.removeValue(forKey: uuid),
               upgradePlaceholder(placeholderID, to: notification, uuid: uuid) {
                return
            }
        }

        guard !isRecentDuplicate(notification) else {
            raiseActiveToHigh(matching: notification)
            return
        }
        if highlightsPriority, activeNotification?.priority == .high, notification.priority != .high {
            heldBehindHigh.append(notification)
            if heldBehindHigh.count > Self.heldLimit { heldBehindHigh.removeFirst() }
            return
        }
        guard activeNotification == nil else {
            guard isUserPresent else {
                show(notification)
                return
            }
            guard !queuedNotifications.contains(where: { $0.id == notification.id }) else { return }
            queuedNotifications.append(notification)
            if queuedNotifications.count > queueLimit {
                queuedNotifications.removeFirst()
            }
            return
        }
        show(notification)
    }

    // MARK: Early placeholder

    private func noteArrival(_ notification: SystemNotification) {
        let now = Date()
        recentArrivals.removeAll { now.timeIntervalSince($0.date) > 10 }
        recentArrivals.append((now, notification.bundleID.map(Self.normalizedID), notification.appName.map(Self.normalizedID)))
    }

    private static func normalizedID(_ value: String) -> String {
        normalizeBundleIdentifier(value).lowercased()
    }

    /// A notification just reached the system: if nothing real for that app
    /// shows up soon (the banner reader would have, within a fraction of a
    /// second), show the app now and let the text catch up.
    private func handleEarlySignal(_ payload: [String: String]) {
        lastEarlyAt = Date()
        guard Defaults[.notificationLiveActivity], Defaults[.notificationFromDatabase],
              Defaults[.notificationEarlyPlaceholder],
              let rawBundleID = nonEmpty(payload["bundleID"]),
              let uuid = nonEmpty(payload["recordUUID"]) else { return }

        let signalTime = Date()
        // The identifier may differ in case from the installed app's.
        let info = Self.appInfo(forBundleID: rawBundleID)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.placeholderDelay))
            await self?.showPlaceholder(bundleID: info.bundleID, appName: info.name, uuid: uuid, signalTime: signalTime)
        }
    }

    private static func appInfo(forBundleID rawBundleID: String) -> (bundleID: String, name: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawBundleID),
           let bundle = Bundle(url: url) {
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return (bundle.bundleIdentifier ?? normalizeBundleIdentifier(rawBundleID), name)
        }
        let normalized = normalizeBundleIdentifier(rawBundleID)
        return (normalized, normalized.split(separator: ".").last.map(String.init) ?? normalized)
    }

    private func showPlaceholder(bundleID: String, appName: String, uuid: String, signalTime: Date) {
        guard !dismissedPlaceholders.contains(uuid), placeholderIDs[uuid] == nil else { return }
        let id = Self.normalizedID(bundleID)
        let name = Self.normalizedID(appName)
        // Real content for this app already arrived (banner reader, or the
        // database was early this time): nothing to hold the place for.
        let alreadyHere = recentArrivals.contains { arrival in
            arrival.date >= signalTime.addingTimeInterval(-0.3)
                && (arrival.bundleID == id || arrival.appName == name || arrival.appName == id)
        }
        guard !alreadyHere else { return }

        let placeholder = SystemNotification(
            id: "early-\(uuid)",
            appName: appName,
            bundleID: bundleID,
            title: String(localized: "New notification"),
            subtitle: nil,
            body: nil,
            receivedAt: signalTime,
            recordUUID: uuid,
            isPlaceholder: true
        )
        guard isAllowed(placeholder) else { return }
        placeholderIDs[uuid] = placeholder.id

        if highlightsPriority, activeNotification?.priority == .high {
            // Don't push a high-priority notification off for an unknown one;
            // its text arrives later through the normal path and waits then.
            placeholderIDs[uuid] = nil
            return
        }
        guard activeNotification == nil else {
            guard isUserPresent else {
                show(placeholder)
                return
            }
            queuedNotifications.append(placeholder)
            if queuedNotifications.count > queueLimit { queuedNotifications.removeFirst() }
            return
        }
        show(placeholder)
    }

    /// Puts the real text into the placeholder's slot without re-animating it.
    private func upgradePlaceholder(_ placeholderID: String, to real: SystemNotification, uuid: String) -> Bool {
        let upgraded = SystemNotification(
            id: placeholderID, appName: real.appName ?? nil, bundleID: real.bundleID,
            title: real.title, subtitle: real.subtitle, body: real.body,
            receivedAt: real.receivedAt, recordUUID: uuid, isPlaceholder: false,
            priority: real.priority
        )
        // Remember the text so a late copy isn't shown again, but only once
        // the placeholder is really still there: a placeholder that was
        // pushed off by another notification must not swallow its own text.
        let isActive = activeNotification?.id == placeholderID
        let isQueued = queuedNotifications.contains { $0.id == placeholderID }
        guard isActive || isQueued else { return false }
        _ = isRecentDuplicate(real)

        if isActive {
            activeNotification = upgraded
            // Give the text its full time on screen, counted from now.
            if !isUserPresent {
                dismissTask?.cancel()
                scheduleDismiss(for: placeholderID)
            }
            return true
        }
        if let index = queuedNotifications.firstIndex(where: { $0.id == placeholderID }) {
            queuedNotifications[index] = upgraded
            return true
        }
        return false
    }

    /// The same notification can arrive from both sources: the banner reader
    /// is immediate, the database copy lands several seconds later. Match on
    /// title and the start of the text, over a window long enough to cover
    /// that delay, and show it once.
    private static func dedupeKey(_ notification: SystemNotification) -> String {
        [notification.title ?? "", String((notification.body ?? "").prefix(40))].joined(separator: "\u{1F}")
    }

    private var highlightsPriority: Bool { Defaults[.notificationPriorityHighlight] }

    /// The banner reader shows a notification before the database says how
    /// important it is; when the database copy arrives, promote the one on screen.
    private func raiseActiveToHigh(matching notification: SystemNotification) {
        guard highlightsPriority, notification.priority == .high,
              var active = activeNotification, active.priority != .high,
              Self.dedupeKey(active) == Self.dedupeKey(notification) else { return }
        active.priority = .high
        activeNotification = active
        if !isUserPresent {
            dismissTask?.cancel()
            scheduleDismiss(for: active.id)
        }
    }

    private func isRecentDuplicate(_ notification: SystemNotification) -> Bool {
        let key = Self.dedupeKey(notification)
        let now = Date()
        recentKeys = recentKeys.filter { now.timeIntervalSince($0.value) < Self.duplicateWindow }
        if recentKeys[key] != nil { return true }
        recentKeys[key] = now
        return false
    }

    private static let duplicateWindow: TimeInterval = 12
    private static let highPriorityDurationFactor: Double = 2
    private static let placeholderMinimumDuration: TimeInterval = 9
    /// How long to wait for the banner reader or the database to produce
    /// the real notification before showing a placeholder for it.
    private static let placeholderDelay: TimeInterval = 0.6

    private func show(_ notification: SystemNotification) {
        dismissTask?.cancel()
        activeNotification = notification
        scheduleDismiss(for: notification.id)
    }

    private func scheduleDismiss(for token: String) {
        // The database delivers the text about five seconds after the
        // notification, so a placeholder must outlive that, whatever the
        // display time is set to.
        let isPlaceholder = activeNotification?.id == token && activeNotification?.isPlaceholder == true
        var duration = isPlaceholder ? max(displayDuration, Self.placeholderMinimumDuration) : displayDuration
        if highlightsPriority, activeNotification?.id == token, activeNotification?.priority == .high {
            duration *= Self.highPriorityDurationFactor
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await self?.dismissActive(token: token, byUser: false)
        }
    }

    private func promoteNext() {
        guard activeNotification == nil, !queuedNotifications.isEmpty else { return }
        show(queuedNotifications.removeFirst())
    }

    func updateFilter() {
        XPCHelperClient.shared.setNotificationFilter(
            bundleIDs: Defaults[.notificationAllowedApps],
            allApps: Defaults[.notificationsFromAllApps]
        )
    }

    private func isAllowed(_ notification: SystemNotification) -> Bool {
        if Defaults[.notificationsFromAllApps] { return true }
        if let bundleID = notification.bundleID {
            return Defaults[.notificationAllowedApps].contains(bundleID)
        }
        guard let appName = notification.appName.map(BundleIDResolver.normalizedAppName),
              !appName.isEmpty else {
            return false
        }
        return Defaults[.notificationAllowedApps].contains { bundleID in
            guard let lastComponent = bundleID.split(separator: ".").last else { return false }
            return appName == BundleIDResolver.normalizedAppName(String(lastComponent))
        }
    }

    private func candidateBundleIDs(for notification: SystemNotification) -> [String] {
        let resolved: String?
        if let bundleID = notification.bundleID, isLaunchable(bundleID) {
            resolved = nil
        } else {
            resolved = notification.appName.flatMap {
                BundleIDResolver.shared.bundleID(forAppNamed: $0)
            }
        }
        return Self.bundleIDCandidates(for: notification, resolvedBundleID: resolved)
    }

    nonisolated static func bundleIDCandidates(
        for notification: SystemNotification,
        resolvedBundleID: String? = nil
    ) -> [String] {
        var result: [String] = []
        for candidate in [notification.bundleID, resolvedBundleID].compactMap({ $0 }) {
            let normalized = normalizeBundleIdentifier(candidate)
            guard !normalized.isEmpty, !result.contains(normalized) else { continue }
            result.append(normalized)
        }
        return result
    }

    private func isLaunchable(_ bundleID: String) -> Bool {
        let workspace = NSWorkspace.shared
        return workspace.urlForApplication(withBundleIdentifier: bundleID) != nil
            || workspace.runningApplications.contains { application in
                guard !application.isTerminated,
                      let applicationBundleID = application.bundleIdentifier else { return false }
                return normalizeBundleIdentifier(applicationBundleID) == bundleID
            }
    }

    private func launchApplication(at appURL: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Test notifications

enum NotificationTestKind: String, CaseIterable, Identifiable {
    /// A real notification from this app, so it travels the whole way through
    /// the system: banner, database, early signal.
    case system
    /// Handed straight to the notch, skipping the system.
    case ordinary
    case timeSensitive

    var id: String { rawValue }
}

extension SystemNotificationManager {
    /// Sends a test notification of the given kind. For `.system`, `completion`
    /// reports whether the system allowed this app to post.
    func sendTest(_ kind: NotificationTestKind, completion: @escaping (Bool) -> Void = { _ in }) {
        switch kind {
        case .system:
            TestNotificationSender.shared.send(completion: completion)
        case .ordinary, .timeSensitive:
            add([
                "token": "test-\(UUID().uuidString)",
                "appName": "Boring Notch",
                "bundleID": Bundle.main.bundleIdentifier ?? "",
                "title": String(localized: "Test notification"),
                "body": String(localized: "If you can read this, notifications reach the notch."),
                "priority": kind == .timeSensitive ? "high" : "normal"
            ])
            completion(true)
        }
    }
}

/// Posts a real notification from Boring Notch itself. The delegate lets it
/// appear as a banner even while the settings window is in front.
final class TestNotificationSender: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TestNotificationSender()

    func send(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Test notification")
            content.body = String(localized: "If you can read this, notifications reach the notch.")
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )
            center.add(request)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
