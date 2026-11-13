//
//  EarlyNotificationSource.swift
//  BoringNotchXPCHelper
//
import Foundation

/// An early "a notification just arrived" signal.
///
/// The notification database only gets a notification about five seconds after
/// it was posted, and the banner is the only other place its text shows up.
/// But the notification service logs the arrival of every notification at once,
/// with the app's bundle identifier and the notification's UUID (its text is
/// redacted). This runs `log stream` for just that line and reports it.
final class EarlyNotificationSource {
    /// Called on the main queue with the app's bundle identifier and the first
    /// eight hex digits of the notification's UUID.
    var onSignal: ((_ bundleID: String, _ uuidPrefix: String) -> Void)?

    private let queue = DispatchQueue(label: "boringNotch.earlySignal")
    private var process: Process?
    private var buffer = Data()
    private var wanted = false

    private static let predicate = #"process == "usernoted" AND eventMessage BEGINSWITH "Added request <NotificationRecord""#
    private static let appPattern = try? NSRegularExpression(pattern: #"app:"([^"]+)""#)
    private static let requestPattern = try? NSRegularExpression(pattern: #"req:"([^"]*)""#)
    private static let categoryPattern = try? NSRegularExpression(pattern: #"category:"([^"]*)""#)
    private static let uuidPattern = try? NSRegularExpression(pattern: #"uuid:"([0-9A-Fa-f]+)""#)

    /// Whether the `log stream` process is alive right now, and its pid.
    var status: (running: Bool, pid: Int32) {
        queue.sync {
            guard let process, process.isRunning else { return (false, 0) }
            return (true, process.processIdentifier)
        }
    }

    @discardableResult
    func start() -> Bool {
        queue.sync {
            wanted = true
            return launch()
        }
    }

    func stop() {
        queue.sync {
            wanted = false
            process?.terminate()
            process = nil
            buffer.removeAll()
        }
    }

    /// Runs the command after the helper's pid and ends it once the helper is
    /// gone. The system kills an XPC service outright when its app quits, so
    /// the helper gets no chance to stop `log stream` itself; without this it
    /// would linger, orphaned, until a notification made it write to its
    /// closed pipe. Checked every 5 seconds; a stop from the helper (SIGTERM)
    /// ends it too.
    private static let watchdog = #"""
    helper=$1; shift
    "$@" & child=$!
    trap 'kill "$child" 2>/dev/null; exit 0' TERM INT HUP
    while kill -0 "$helper" 2>/dev/null && kill -0 "$child" 2>/dev/null; do sleep 5; done
    kill "$child" 2>/dev/null
    wait "$child"
    """#

    /// A `log stream` left behind by an earlier helper that was killed would
    /// otherwise linger until the next notification makes it write to its
    /// closed pipe. Done once per helper process.
    private static let reapedLeftovers: Void = {
        let reaper = Process()
        reaper.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        reaper.arguments = ["-f", #"log stream .*Added request <NotificationRecord"#]
        reaper.standardOutput = FileHandle.nullDevice
        reaper.standardError = FileHandle.nullDevice
        try? reaper.run()
        reaper.waitUntilExit()
    }()

    private func launch() -> Bool {
        guard process == nil else { return true }
        _ = Self.reapedLeftovers
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.watchdog, "sh", String(getpid()),
                             "/usr/bin/log", "stream", "--style", "ndjson", "--level", "info", "--predicate", Self.predicate]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] finished in
            self?.queue.async {
                guard let self else { return }
                if self.process === finished { self.process = nil }
                // It died by itself while still wanted: try again shortly.
                guard self.wanted else { return }
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.wanted, self.process == nil else { return }
                    _ = self.launch()
                }
            }
        }
        do {
            try process.run()
        } catch {
            NSLog("[NekoNotch] early notification signal could not start: \(error.localizedDescription)")
            return false
        }
        self.process = process
        buffer.removeAll()
        return true
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: line)
        }
        // A runaway line without a newline would grow forever.
        if buffer.count > 1_000_000 { buffer.removeAll() }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = object["eventMessage"] as? String,
              let bundleID = Self.firstMatch(Self.appPattern, in: message),
              let uuid = Self.firstMatch(Self.uuidPattern, in: message) else { return }
        // Badge-only updates (Reminders sends one every midnight) are logged
        // like any other notification but have no text and are never shown.
        let identifiers = [Self.firstMatch(Self.requestPattern, in: message),
                           Self.firstMatch(Self.categoryPattern, in: message)]
        if identifiers.contains(where: { $0?.localizedCaseInsensitiveContains("badge") == true }) { return }
        DispatchQueue.main.async { [weak self] in
            self?.onSignal?(bundleID, uuid.uppercased())
        }
    }

    private static func firstMatch(_ regex: NSRegularExpression?, in text: String) -> String? {
        guard let regex,
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
