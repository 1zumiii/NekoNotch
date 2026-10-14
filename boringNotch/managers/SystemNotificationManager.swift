//
//  SystemNotificationManager.swift
//  boringNotch
//
import AppKit
import Combine
import Defaults

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
    /// Placeholder id by notification UUID, so the real text can replace it in place.
    private var placeholderIDs: [String: String] = [:]
    /// UUIDs of placeholders the user closed: their text must not pop back up.
    private var dismissedPlaceholders = Set<String>()
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
        updateDatabaseWatcher()
        guard await XPCHelperClient.shared.isAccessibilityAuthorized() else { return }
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
        activeNotification = nil
        if isUserPresent {
            promoteNext()
        } else {
            queuedNotifications.removeAll()
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
            receivedAt: Date()
        )
        guard isAllowed(notification) else { return }
        noteArrival(notification)

        // The text for a notification already on screen as a placeholder.
        if let uuid = nonEmpty(payload["recordUUID"]) {
            if dismissedPlaceholders.remove(uuid) != nil { return }
            if let placeholderID = placeholderIDs.removeValue(forKey: uuid),
               upgradePlaceholder(placeholderID, to: notification, uuid: uuid) {
                return
            }
        }

        guard !isRecentDuplicate(notification) else { return }
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
            receivedAt: real.receivedAt, recordUUID: uuid, isPlaceholder: false
        )
        _ = isRecentDuplicate(real)   // remember the text so a late copy isn't shown again

        if activeNotification?.id == placeholderID {
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
    private func isRecentDuplicate(_ notification: SystemNotification) -> Bool {
        let key = [notification.title ?? "", String((notification.body ?? "").prefix(40))]
            .joined(separator: "\u{1F}")
        let now = Date()
        recentKeys = recentKeys.filter { now.timeIntervalSince($0.value) < Self.duplicateWindow }
        if recentKeys[key] != nil { return true }
        recentKeys[key] = now
        return false
    }

    private static let duplicateWindow: TimeInterval = 12
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
        let duration = isPlaceholder ? max(displayDuration, Self.placeholderMinimumDuration) : displayDuration
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
