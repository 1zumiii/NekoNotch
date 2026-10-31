//
//  FocusStatusMonitor.swift
//  boringNotch
//
import Combine
import Defaults
import Foundation

/// What the notch does with notifications while a Focus is on.
enum FocusNotificationBehavior: String, CaseIterable, Identifiable, Defaults.Serializable {
    /// Only what the system itself lets through the Focus: notifications that
    /// still get a banner, and time-sensitive ones. The database reader would
    /// otherwise show what the Focus silenced.
    case follow
    case showAll
    case hideAll

    var id: String { rawValue }
}

/// Whether a Focus is on, read from the Focus service's own store, which
/// needs Full Disk Access. A Focus turned on by hand, from Control Center, a
/// shortcut or another device, is an assertion in that store; one that starts
/// on a schedule is worked out by the system as it goes and isn't seen here.
@MainActor
final class FocusStatusMonitor: ObservableObject {
    static let shared = FocusStatusMonitor()

    struct Focus: Equatable {
        let identifier: String
        let name: String?
        let symbol: String?
    }

    @Published private(set) var current: Focus?

    var isFocused: Bool { current != nil }

    private let queue = DispatchQueue(label: "boringNotch.focusStatus", qos: .utility)
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var fallbackTimer: Timer?
    private var pendingRefresh: DispatchWorkItem?

    /// File events can be missed (the store rebuilt, a sleep in between).
    private static let fallbackInterval: TimeInterval = 60
    /// The service writes several files in a row; read once they're done.
    private static let settleDelay: DispatchTimeInterval = .milliseconds(200)

    private nonisolated static var directory: String {
        // NSHomeDirectory() is the sandbox container inside a sandboxed app.
        let home = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return home + "/Library/DoNotDisturb/DB"
    }

    private init() {}

    func start() {
        guard fallbackTimer == nil else { return }
        scheduleRefresh()

        // The store's files are replaced, not written in place, which shows
        // as a change to the directory.
        let descriptor = open(Self.directory, O_EVTONLY)
        if descriptor >= 0 {
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue
            )
            watcher.setEventHandler { [weak self] in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            watcher.setCancelHandler { close(descriptor) }
            watcher.resume()
            directoryWatcher = watcher
        }

        let timer = Timer(timeInterval: Self.fallbackInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    func stop() {
        directoryWatcher?.cancel()
        directoryWatcher = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        current = nil
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let focus = Self.readCurrentFocus()
            Task { @MainActor in
                guard let self, self.fallbackTimer != nil else { return }
                if self.current != focus { self.current = focus }
            }
        }
        pendingRefresh = work
        queue.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private nonisolated static func readJSON(_ name: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: directory + "/" + name) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The Focus of the newest active assertion, with its name and symbol
    /// from the mode configurations.
    private nonisolated static func readCurrentFocus() -> Focus? {
        guard let assertions = readJSON("Assertions.json"),
              let stores = assertions["data"] as? [[String: Any]] else { return nil }
        let records = stores.flatMap { $0["storeAssertionRecords"] as? [[String: Any]] ?? [] }
        let newest = records.max { lhs, rhs in
            (lhs["assertionStartDateTimestamp"] as? Double ?? 0) < (rhs["assertionStartDateTimestamp"] as? Double ?? 0)
        }
        guard let newest else { return nil }
        let details = newest["assertionDetails"] as? [String: Any]
        let identifier = details?["assertionDetailsModeIdentifier"] as? String ?? "com.apple.donotdisturb.mode.default"

        let configurations = (readJSON("ModeConfigurations.json")?["data"] as? [[String: Any]])?
            .compactMap { $0["modeConfigurations"] as? [String: Any] }
            .first
        let mode = (configurations?[identifier] as? [String: Any])?["mode"] as? [String: Any]
        return Focus(
            identifier: identifier,
            name: mode?["name"] as? String,
            symbol: mode?["symbolImageName"] as? String
        )
    }
}
