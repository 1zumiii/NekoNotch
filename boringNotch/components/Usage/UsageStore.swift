//
//  UsageStore.swift
//  boringNotch
//
//  Reads the usage files that the collector scripts in scripts/ write (see
//  scripts/AI_USAGE.md) so the notch can draw its own gauges. Read-only; no
//  credentials or network access are involved.
//
import Combine
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
    var staleAt: Date? = nil

    func isStale(at now: Date) -> Bool {
        guard let lastUpdatedDate else { return true }
        return now.timeIntervalSince(lastUpdatedDate) > 15 * 60 || staleAt.map { now >= $0 } == true
    }

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
            relativePath: "Library/Application Support/RunCatIntegrations/claude-app-quota.json",
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

    static let claudeCLI = UsageSource(
        id: "claudeCLI", displayName: "Claude CLI", icon: "staroflife",
        relativePath: "Library/Application Support/RunCatIntegrations/claude-cli-limits.json",
        tint: Color(red: 0.85, green: 0.47, blue: 0.34)
    )
}

/// Decode each account's original sample; never select between accounts by age.
enum ClaudeQuotaDecoder {
    private struct History: Decodable {
        let version: Int
        let samples: [Sample]
    }
    private struct Sample: Decodable {
        let t: Double
        let u: Values?
        let fh: Double?
        let sd: Double?
    }
    private struct Values: Decodable {
        let fh: Double?
        let sd: Double?
    }
    private struct Limits: Decodable {
        let t: Double
        let five_hour: Window?
        let seven_day: Window?
    }
    private struct Window: Decodable {
        let used: Double?
        let resets_at: Double?
    }
    private static func metric(_ title: String, _ value: Double?) -> UsageMetric? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return UsageMetric(title: title, formattedValue: String(format: "%g%%", value), normalizedValue: value / 100)
    }
    static func app(_ data: Data) throws -> UsageSnapshot? {
        let history = try JSONDecoder().decode(History.self, from: data)
        guard (1...2).contains(history.version), let sample = history.samples.max(by: { $0.t < $1.t }) else { return nil }
        let metrics = [metric("5h", history.version == 2 ? sample.u?.fh : sample.fh),
                       metric("7d", history.version == 2 ? sample.u?.sd : sample.sd)].compactMap { $0 }
        guard !metrics.isEmpty else { return nil }
        return UsageSnapshot(title: "Claude App", symbol: "staroflife", metrics: metrics,
                             lastUpdatedDate: Date(timeIntervalSince1970: sample.t / 1000))
    }
    static func cli(_ data: Data) throws -> UsageSnapshot? {
        let limits = try JSONDecoder().decode(Limits.self, from: data)
        let metrics = [metric("5h", limits.five_hour?.used), metric("7d", limits.seven_day?.used)].compactMap { $0 }
        guard !metrics.isEmpty else { return nil }
        // A passed reset time makes the old sample stale, not a new 0% sample.
        let reset = [limits.five_hour?.resets_at, limits.seven_day?.resets_at].compactMap { $0 }.min()
        return UsageSnapshot(title: "Claude CLI", symbol: "staroflife", metrics: metrics,
                             lastUpdatedDate: Date(timeIntervalSince1970: limits.t),
                             staleAt: reset.map { Date(timeIntervalSince1970: $0) })
    }
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
        for source in UsageSource.all + [UsageSource.claudeCLI] {
            let modified = (try? source.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard modified != modificationDates[source.id] else { continue }

            // Preserve the last valid sample during a partial write or a
            // temporarily unavailable file. Its original date continues aging.
            guard let data = try? Data(contentsOf: source.url) else { continue }
            let snapshot: UsageSnapshot?
            switch source.id {
            case "claude": snapshot = try? ClaudeQuotaDecoder.app(data)
            case "claudeCLI": snapshot = try? ClaudeQuotaDecoder.cli(data)
            default: snapshot = try? Self.decoder.decode(UsageSnapshot.self, from: data)
            }
            if let snapshot {
                snapshots[source.id] = snapshot
                modificationDates[source.id] = modified
            }
        }
    }
}
