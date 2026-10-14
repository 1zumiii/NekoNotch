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
    private static let uuidPattern = try? NSRegularExpression(pattern: #"uuid:"([0-9A-Fa-f]+)""#)

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

    private func launch() -> Bool {
        guard process == nil else { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--level", "info", "--predicate", Self.predicate]
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
            NSLog("[boringNotch] early notification signal could not start: \(error.localizedDescription)")
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
