//
//  ClaudeCodeStatsWidgetView.swift
//  boringNotch
//
import SwiftUI

/// Deduplicated local transcript usage, grouped by provider and UTC day.
/// `estimated` is the part of the Claude numbers recovered from Claude Code's
/// stats-cache.json for sessions whose transcripts were deleted.
struct ClaudeCodeStats: Decodable, Equatable {
    let total: Double
    let last7: Double
    let days: [String: [String: Double]]
    let totals: [String: Double]
    let estimated: Double?
    let updated: String
    let readErrors: Int
}

/// Local Claude and Codex totals with a blended-color daily heat map.
struct ClaudeCodeStatsWidgetView: View {
    static let tint = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codexTint = Color(red: 0.64, green: 0.42, blue: 0.92)

    let size: CGSize

    @State private var stats: ClaudeCodeStats?

    init(size: CGSize) {
        self.size = size
        // Read once up front so the first frame already has numbers.
        _stats = State(initialValue: Self.load())
    }

    private var isStrip: Bool { size.height < 90 }
    private var title: String { String(localized: "AI Tokens") }

    private static let fileURL: URL = {
        let path = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("Library/Application Support/RunCatIntegrations/ai-token-stats.json")
    }()

    private static func load() -> ClaudeCodeStats? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ClaudeCodeStats.self, from: data)
    }

    /// 6 840 000 000 → "6.8b", like the terminal screen.
    private static func compact(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "%.1fb", value / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fm", value / 1_000_000)
        case 1_000...: return String(format: "%.1fk", value / 1_000)
        default: return String(format: "%.0f", value)
        }
    }

    var body: some View {
        Group {
            if isStrip {
                strip
            } else {
                card
            }
        }
        .frame(width: size.width, height: size.height)
        .help(details)
        .task {
            // Only while the dashboard is on screen; the file is a few kilobytes.
            while !Task.isCancelled {
                let loaded = Self.load()
                if loaded != stats { stats = loaded }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var details: String {
        guard let stats else { return String(localized: "No usage data yet") }
        let summary = "Claude: \(Self.compact(stats.totals["claude"] ?? 0))\nCodex: \(Self.compact(stats.totals["codex"] ?? 0))"
        let estimate = (stats.estimated ?? 0) > 0
            ? "\n" + String(localized: "Includes \(Self.compact(stats.estimated ?? 0)) estimated from Claude Code's statistics for sessions whose transcripts were deleted.")
            : ""
        return summary + estimate + "\n" + String(localized: "Local transcripts only; includes cache tokens. Claude chats without token records are excluded. Days use UTC.")
            + "\n" + String(localized: "Updated") + ": " + stats.updated
            + (stats.readErrors > 0 ? "\n" + String(localized: "Some usage files could not be read") : "")
    }

    private var legend: some View {
        HStack(spacing: 9) {
            Label("Claude", systemImage: "circle.fill").foregroundStyle(Self.tint)
            Label("Codex", systemImage: "circle.fill").foregroundStyle(Self.codexTint)
        }
        .font(.system(size: 8, weight: .medium))
        .lineLimit(1)
        .fixedSize()
    }

    // MARK: Two rows tall

    private var card: some View {
        DashboardCard(icon: "square.grid.3x3.fill", tint: Self.tint, title: title) {
            if let stats {
                Text(verbatim: String(localized: "7d") + " " + Self.compact(stats.last7))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
        } content: {
            if let stats {
                Spacer(minLength: 4)
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: Self.compact(stats.total))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Self.tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("Total tokens")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(width: size.width < 220 ? 62 : 74, alignment: .leading)
                    HeatMap(days: stats.days, tint: Self.tint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.top, 2)
                legend.padding(.top, 5)
            } else {
                emptyState
            }
        }
    }

    // MARK: One row tall

    private var strip: some View {
        DashboardCardChrome(tint: Self.tint) {
            if let stats {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        DashboardCardTitle(icon: "square.grid.3x3.fill", tint: Self.tint, title: title)
                        Text(verbatim: Self.compact(stats.total))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Self.tint)
                            .lineLimit(1)
                            .fixedSize()
                        Text(verbatim: String(localized: "7d") + " " + Self.compact(stats.last7))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxHeight: .infinity)

                    // Narrow: the numbers go under the title.
                    VStack(alignment: .leading, spacing: 7) {
                        DashboardCardTitle(icon: "square.grid.3x3.fill", tint: Self.tint, title: title)
                        HStack(spacing: 8) {
                            Text(verbatim: Self.compact(stats.total))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Self.tint)
                            Text(verbatim: String(localized: "7d") + " " + Self.compact(stats.last7))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .fixedSize()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        Text("No usage data yet")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Weeks as columns, Monday to Sunday as rows, newest week on the right. The
/// shade follows the logarithm of the day's tokens, since a few huge days would
/// otherwise turn every other day into the faintest square.
private struct HeatMap: View {
    let days: [String: [String: Double]]
    let tint: Color

    private static let gap: CGFloat = 2.5
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    var body: some View {
        Canvas { context, canvasSize in
            let gap = Self.gap
            let side = floor((canvasSize.height - gap * 6) / 7)
            guard side > 2 else { return }
            let columns = max(1, min(26, Int((canvasSize.width + gap) / (side + gap))))

            let calendar = Self.utc
            let today = calendar.startOfDay(for: Date())
            // Monday of the current week, then back to the first visible week.
            let sinceMonday = (calendar.component(.weekday, from: today) + 5) % 7  // weekday: 1 = Sunday
            guard let thisMonday = calendar.date(byAdding: .day, value: -sinceMonday, to: today),
                  let firstMonday = calendar.date(byAdding: .weekOfYear, value: -(columns - 1), to: thisMonday)
            else { return }

            let peak = days.values.map { $0.values.reduce(0, +) }.max() ?? 0
            let scale = peak > 0 ? log10(1 + peak) : 1
            let gridWidth = CGFloat(columns) * (side + gap) - gap
            let originX = canvasSize.width - gridWidth

            for column in 0..<columns {
                for row in 0..<7 {
                    guard let date = calendar.date(byAdding: .day, value: column * 7 + row, to: firstMonday),
                          date <= today else { continue }
                    let usage = days[Self.formatter.string(from: date)] ?? [:]
                    let tokens = usage.values.reduce(0, +)
                    let color: Color
                    if tokens <= 0 {
                        color = Color.white.opacity(0.08)
                    } else {
                        // Four shades, like the terminal screen.
                        let level = min(3, Int((log10(1 + tokens) / scale) * 4))
                        let codexShare = min(1, max(0, (usage["codex"] ?? 0) / tokens))
                        // Deepen the mixed shade instead of desaturating it.
                        // Pure-provider days keep their legend color; opacity
                        // remains tied only to the total token volume.
                        let overlap = 4 * codexShare * (1 - codexShare)
                        color = Color(
                            red: (0.85 + (0.64 - 0.85) * codexShare) * (1 - 0.06 * overlap),
                            green: (0.47 + (0.42 - 0.47) * codexShare) * (1 - 0.35 * overlap),
                            blue: (0.34 + (0.92 - 0.34) * codexShare) * (1 - 0.04 * overlap)
                        ).opacity(0.28 + 0.24 * Double(level))
                    }
                    let rect = CGRect(
                        x: originX + CGFloat(column) * (side + gap),
                        y: CGFloat(row) * (side + gap),
                        width: side,
                        height: side
                    )
                    context.fill(Path(roundedRect: rect, cornerRadius: side * 0.25), with: .color(color))
                }
            }
        }
    }
}
