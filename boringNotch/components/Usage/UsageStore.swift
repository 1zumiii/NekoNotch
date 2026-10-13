//
//  UsageStore.swift
//  boringNotch
//
//  Reads the usage snapshots that RunCat's integration scripts write
//  (title / metrics[] / lastUpdatedDate) so the notch can draw its own gauges.
//  Read-only; no credentials or network access are involved.
//
import Combine
import Defaults
import Foundation
import SwiftUI

struct UsageMetric: Decodable, Equatable {
    let title: String
    let formattedValue: String
    let normalizedValue: Double?
}

struct UsageSnapshot: Decodable, Equatable {
    let title: String
    let symbol: String?
    let metrics: [UsageMetric]
    let lastUpdatedDate: Date?

    /// Rate-limit windows such as "5h" or "7d", drawn as rings.
    var windows: [UsageMetric] {
        metrics.filter { $0.normalizedValue != nil && Self.isWindowTitle($0.title) }
    }

    /// Other measured values (context size, per-model weekly limits), drawn as bars.
    var bars: [UsageMetric] {
        metrics.filter { $0.normalizedValue != nil && !Self.isWindowTitle($0.title) }
    }

    var model: String? {
        metrics.first { $0.title == "Model" }?.formattedValue
    }

    private static func isWindowTitle(_ title: String) -> Bool {
        guard let last = title.last, "mhd".contains(last) else { return false }
        return Double(title.dropLast()) != nil
    }
}

struct UsageSource: Identifiable {
    let id: String
    let displayName: String
    let icon: String
    let relativePath: String
    let tint: Color

    var url: URL { Self.homeDirectory.appendingPathComponent(relativePath) }

    /// NSHomeDirectory() is the sandbox container inside a sandboxed app.
    private static let homeDirectory: URL = {
        let path = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    static let all: [UsageSource] = [
        UsageSource(
            id: "claude",
            displayName: "Claude",
            icon: "staroflife",
            relativePath: "Library/Application Support/RunCatIntegrations/claude-usage.json",
            tint: Color(red: 0.85, green: 0.47, blue: 0.34)
        ),
        UsageSource(
            id: "codex",
            displayName: "Codex",
            icon: "camera.aperture",
            relativePath: ".codex/runcat-usage.json",
            tint: Color(red: 0.36, green: 0.62, blue: 1.0)
        )
    ]
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var snapshots: [String: UsageSnapshot] = [:]

    private var modificationDates: [String: Date] = [:]
    private var timer: Timer?
    private var watchers = 0

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Polls only while a usage page is on screen.
    func beginWatching() {
        watchers += 1
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        for source in UsageSource.all {
            let modified = (try? source.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard modified != modificationDates[source.id] else { continue }
            modificationDates[source.id] = modified

            guard let data = try? Data(contentsOf: source.url),
                  let snapshot = try? Self.decoder.decode(UsageSnapshot.self, from: data) else {
                snapshots[source.id] = nil
                continue
            }
            snapshots[source.id] = snapshot
        }
    }
}
