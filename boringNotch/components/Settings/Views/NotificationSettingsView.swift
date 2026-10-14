//
//  NotificationSettingsView.swift
//  boringNotch
//
import AppKit
import Defaults
import SwiftUI

private struct NotificationApp: Identifiable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}

private enum ServiceState {
    case running, off, warning, failed

    var color: Color {
        switch self {
        case .running: .green
        case .off: .secondary
        case .warning: .orange
        case .failed: .red
        }
    }
}

private struct ServiceRow: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let state: ServiceState
    let status: LocalizedStringKey
    var detail: String?
}

struct NotificationSettingsView: View {
    @Default(.notificationLiveActivity) private var notificationLiveActivity
    @Default(.notificationsFromAllApps) private var notificationsFromAllApps
    @Default(.notificationAllowedApps) private var allowedApps
    @Default(.notificationDisplayDuration) private var displayDuration
    @Default(.notificationFromDatabase) private var fromDatabase
    @Default(.notificationEarlyPlaceholder) private var earlyPlaceholder
    @State private var isAccessibilityAuthorized = true
    @State private var hasDatabaseAccess = true
    @State private var helperStatus: [String: NSNumber]?
    @State private var helperChecked = false
    @State private var isRestarting = false
    @State private var testKind: NotificationTestKind = .system
    @State private var testDenied = false
    @ObservedObject private var manager = SystemNotificationManager.shared

    private var selectedApps: [NotificationApp] {
        allowedApps
            .map { NotificationApp(bundleID: $0, name: displayName(for: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private var databaseSection: some View {
            Section {
                Defaults.Toggle(key: .notificationFromDatabase) {
                    Text("Read notifications from the system database")
                }
                .disabled(!notificationLiveActivity)

                if fromDatabase {
                    Defaults.Toggle(key: .notificationEarlyPlaceholder) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show the app at once")
                            Text("For apps whose banners are off, the notch shows the app the moment its notification arrives, and fills in the text about five seconds later when the system provides it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!notificationLiveActivity)
                    .onChange(of: earlyPlaceholder) { _, _ in
                        SystemNotificationManager.shared.updateDatabaseWatcher()
                    }
                }

                if fromDatabase && !hasDatabaseAccess {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.title)
                            .foregroundStyle(Color.effectiveAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Full Disk Access Required")
                                .font(.headline)
                            Text("Grant Full Disk Access to Boring Notch, then reopen the app.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } footer: {
                Text("Lets you turn off banners for an app in System Settings so nothing flashes on screen; its notifications still appear in the notch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    // MARK: Service status

    private func lastEvent(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return String(localized: "Last event \(formatter.localizedString(for: date, relativeTo: Date()))")
    }

    private var serviceRows: [ServiceRow] {
        let status = helperStatus
        let helperDown = helperChecked && status == nil
        var rows: [ServiceRow] = []

        // The XPC helper process that does the Accessibility and log work.
        if let pid = status?["helperPID"]?.intValue {
            rows.append(ServiceRow(id: "helper", title: "Helper process", state: .running, status: "Running", detail: "PID \(pid)"))
        } else {
            rows.append(ServiceRow(id: "helper", title: "Helper process", state: helperDown ? .failed : .off,
                                   status: helperDown ? "Not responding" : "Checking…"))
        }

        // Banner reader.
        if !notificationLiveActivity {
            rows.append(ServiceRow(id: "banner", title: "Banner reader", state: .off, status: "Off"))
        } else if helperDown {
            rows.append(ServiceRow(id: "banner", title: "Banner reader", state: .failed, status: "Helper not responding"))
        } else if let status {
            let running = status["bannerRunning"]?.boolValue == true
            let trusted = status["axTrusted"]?.boolValue == true
            let attached = status["bannerPID"]?.intValue ?? 0
            let current = status["notificationCenterPID"]?.intValue ?? 0
            if !trusted {
                rows.append(ServiceRow(id: "banner", title: "Banner reader", state: .failed, status: "No Accessibility access"))
            } else if !running {
                rows.append(ServiceRow(id: "banner", title: "Banner reader", state: .failed, status: "Stopped"))
            } else if current != 0, attached != current {
                rows.append(ServiceRow(id: "banner", title: "Banner reader", state: .warning,
                                       status: "Notification Center restarted; restart the services"))
            } else {
                rows.append(ServiceRow(id: "banner", title: "Banner reader", state: .running, status: "Running",
                                       detail: lastEvent(manager.lastBannerAt)))
            }
        }

        // Database reader.
        let database = NotificationDatabaseWatcher.shared.status
        if !notificationLiveActivity || !fromDatabase {
            rows.append(ServiceRow(id: "database", title: "Database reader", state: .off, status: "Off"))
        } else if !hasDatabaseAccess {
            rows.append(ServiceRow(id: "database", title: "Database reader", state: .failed, status: "No Full Disk Access"))
        } else if !database.isRunning {
            rows.append(ServiceRow(id: "database", title: "Database reader", state: .failed, status: "Stopped"))
        } else if database.isFailing {
            rows.append(ServiceRow(id: "database", title: "Database reader", state: .failed, status: "Cannot read the database"))
        } else {
            rows.append(ServiceRow(id: "database", title: "Database reader", state: .running, status: "Running",
                                   detail: lastEvent(manager.lastDatabaseAt)))
        }

        // Early signal.
        if !notificationLiveActivity || !fromDatabase || !earlyPlaceholder {
            rows.append(ServiceRow(id: "early", title: "Early signal", state: .off, status: "Off"))
        } else if helperDown {
            rows.append(ServiceRow(id: "early", title: "Early signal", state: .failed, status: "Helper not responding"))
        } else if let status {
            if status["earlyRunning"]?.boolValue == true {
                rows.append(ServiceRow(id: "early", title: "Early signal", state: .running, status: "Running",
                                       detail: lastEvent(manager.lastEarlyAt)))
            } else {
                rows.append(ServiceRow(id: "early", title: "Early signal", state: .failed, status: "Stopped"))
            }
        }
        return rows
    }

    private var statusSection: some View {
        Section {
            ForEach(serviceRows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(row.state.color)
                        .frame(width: 8, height: 8)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(row.title)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(row.status)
                            .foregroundStyle(row.state == .running || row.state == .off ? Color.secondary : row.state.color)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .multilineTextAlignment(.trailing)
                }
            }
            Button {
                restartServices()
            } label: {
                Label("Restart services", systemImage: "arrow.clockwise")
            }
            .disabled(isRestarting || !notificationLiveActivity)
        } header: {
            Text("Service status")
        } footer: {
            Text("If notifications stop showing up in the notch, check which line is red or orange here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshStatus() async {
        helperStatus = await XPCHelperClient.shared.serviceStatus()
        helperChecked = true
        hasDatabaseAccess = NotificationDatabaseWatcher.hasAccess()
    }

    private func restartServices() {
        isRestarting = true
        Task {
            SystemNotificationManager.shared.stop()
            try? await Task.sleep(for: .milliseconds(600))
            await SystemNotificationManager.shared.start()
            await refreshStatus()
            isRestarting = false
        }
    }

    var body: some View {
        Form {
            statusSection

            Section {
                Defaults.Toggle(key: .notificationLiveActivity) {
                    Text("Show notifications in the notch")
                }
                Defaults.Toggle(key: .notificationAutoExpand) {
                    Text("Expand the notch automatically")
                }
                .disabled(!notificationLiveActivity)
                Defaults.Toggle(key: .notificationPriorityHighlight) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Highlight time-sensitive notifications")
                        Text("They get a rainbow outline, stay twice as long, and are not pushed off by ordinary ones. The importance comes from the database, so it needs the database reader.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!notificationLiveActivity)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Dismiss after")
                        Spacer()
                        Text(verbatim: "\(Int(displayDuration)) s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $displayDuration, in: 2...30, step: 1)
                }
                .disabled(!notificationLiveActivity)
            } footer: {
                Text("Requires \(AccessibilityPermission.displayName). Only visible banners are mirrored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            databaseSection

            Section {
                Picker("Type", selection: $testKind) {
                    Text("Real system notification").tag(NotificationTestKind.system)
                    Text("Ordinary (notch only)").tag(NotificationTestKind.ordinary)
                    Text("Time-sensitive (notch only)").tag(NotificationTestKind.timeSensitive)
                }
                Button {
                    testDenied = false
                    SystemNotificationManager.shared.sendTest(testKind) { allowed in
                        testDenied = !allowed
                    }
                } label: {
                    Label("Send test notification", systemImage: "paperplane")
                }
                .disabled(!notificationLiveActivity)
                if testDenied {
                    Text("Notifications from Boring Notch are turned off in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Test")
            } footer: {
                Text("A real system notification goes through the whole chain and may show a system banner. The notch-only kinds skip the system, which is the only way to try the time-sensitive look.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !isAccessibilityAuthorized {
                Section {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: AccessibilityPermission.systemImageName)
                            .font(.title)
                            .foregroundStyle(Color.effectiveAccent)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(AccessibilityPermission.displayName) Required")
                                .font(.headline)
                            Text("Grant \(AccessibilityPermission.displayName) to mirror notification banners.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Grant Access") {
                            Task {
                                let granted = await MediaKeyInterceptor.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                                isAccessibilityAuthorized = granted
                            }
                        }
                    }
                }
            }

            Section {
                Defaults.Toggle(key: .notificationsFromAllApps) {
                    Text("From all apps")
                }
                .disabled(!notificationLiveActivity)

                if !notificationsFromAllApps {
                    if selectedApps.isEmpty {
                        Text("No apps selected")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedApps) { app in
                            HStack {
                                appIcon(for: app.bundleID)
                                    .resizable().scaledToFit()
                                    .frame(width: 20, height: 20)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))

                                Text(app.name)
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    allowedApps.remove(app.bundleID)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    Button {
                        chooseApplication()
                    } label: {
                        Label("Add Application…", systemImage: "plus")
                    }
                }
            } header: {
                Text("Apps")
            } footer: {
                if !notificationsFromAllApps {
                    Text("Only selected apps are mirrored. Add applications from your Mac; no preset app list is used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!notificationLiveActivity)
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .task {
            isAccessibilityAuthorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
            hasDatabaseAccess = NotificationDatabaseWatcher.hasAccess()
            // Keep the status panel current for as long as the page is open.
            while !Task.isCancelled {
                await refreshStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: fromDatabase) { _, _ in
            hasDatabaseAccess = NotificationDatabaseWatcher.hasAccess()
            SystemNotificationManager.shared.updateDatabaseWatcher()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { notification in
            if let granted = notification.userInfo?["granted"] as? Bool {
                isAccessibilityAuthorized = granted
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                isAccessibilityAuthorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
                hasDatabaseAccess = NotificationDatabaseWatcher.hasAccess()
            }
        }
        .onChange(of: allowedApps) { _, _ in
            SystemNotificationManager.shared.updateFilter()
        }
        .onChange(of: notificationsFromAllApps) { _, _ in
            SystemNotificationManager.shared.updateFilter()
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["app"]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            let bundleIDs = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            guard !bundleIDs.isEmpty else { return }
            DispatchQueue.main.async {
                allowedApps.formUnion(bundleIDs)
            }
        }
    }

    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        else {
            return bundleID
        }
        return name
    }
}
