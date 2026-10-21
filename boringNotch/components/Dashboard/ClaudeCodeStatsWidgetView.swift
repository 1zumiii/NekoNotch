//
//  ClaudeCodeStatsWidgetView.swift
//  boringNotch
//
import SwiftUI

/// What `runcat-app-sync.py` writes for this card: total tokens used with
/// Claude Code, and tokens per UTC day. Read-only.
struct ClaudeCodeStats: Decodable, Equatable {
    let total: Double
    let last7: Double
    let days: [String: Double]
}

/// Total tokens and a heat map of the last weeks, like the Stats screen of the
/// Claude Code terminal app.
struct ClaudeCodeStatsWidgetView: View {
    static let tint = Color(red: 0.85, green: 0.47, blue: 0.34)

    let size: CGSize

    @State private var stats: ClaudeCodeStats?

    init(size: CGSize) {
        self.size = size
        // Read once up front so the first frame already has numbers.
        _stats = State(initialValue: Self.load())
    }

    private var isStrip: Bool { size.height < 90 }
    private var title: String { "Claude Code" }

    private static let fileURL: URL = {
        let path = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("Library/Application Support/RunCatIntegrations/claude-code-stats.json")
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
        .task {
            // Only while the dashboard is on screen; the file is a few kilobytes.
            while !Task.isCancelled {
                let loaded = Self.load()
                if loaded != stats { stats = loaded }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: Two rows tall

    private var card: some View {
        DashboardCard(icon: "square.grid.3x3.fill", tint: Self.tint, title: title) {
            if let stats {
                Text(verbatim: String(localized: "7d") + " " + Self.compact(stats.last7))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } content: {
            if let stats {
                Spacer(minLength: 4)
                HStack(alignment: .center, spacing: 12) {
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
                    .frame(width: 74, alignment: .leading)
                    HeatMap(days: stats.days, tint: Self.tint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.top, 2)
            } else {
                emptyState
            }
        }
    }

    // MARK: One row tall

    private var strip: some View {
        DashboardCardChrome(tint: Self.tint) {
            if let stats {
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
    let days: [String: Double]
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

            let peak = days.values.max() ?? 0
            let scale = peak > 0 ? log10(1 + peak) : 1
            let gridWidth = CGFloat(columns) * (side + gap) - gap
            let originX = canvasSize.width - gridWidth

            for column in 0..<columns {
                for row in 0..<7 {
                    guard let date = calendar.date(byAdding: .day, value: column * 7 + row, to: firstMonday),
                          date <= today else { continue }
                    let tokens = days[Self.formatter.string(from: date)] ?? 0
                    let color: Color
                    if tokens <= 0 {
                        color = Color.white.opacity(0.08)
                    } else {
                        // Four shades, like the terminal screen.
                        let level = min(3, Int((log10(1 + tokens) / scale) * 4))
                        color = tint.opacity(0.28 + 0.24 * Double(level))
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
