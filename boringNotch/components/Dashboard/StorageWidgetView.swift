//
//  StorageWidgetView.swift
//  boringNotch
//
import SwiftUI

/// Free space on the startup volume, read straight from the system.
struct StorageWidgetView: View {
    static let tint = Color(red: 0.30, green: 0.78, blue: 0.62)

    let size: CGSize

    private struct Capacity {
        let total: Int64
        let free: Int64
        var used: Int64 { max(total - free, 0) }
        var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
        var usedPercent: String { "\(Int((usedFraction * 100).rounded()))%" }
    }

    private var isStrip: Bool { size.height < 90 }
    private var title: String { String(localized: "Storage") }

    private static func readCapacity() -> Capacity? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return Capacity(total: Int64(total), free: free)
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let capacity = Self.readCapacity()
            Group {
                if isStrip {
                    strip(capacity)
                } else {
                    card(capacity)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: Two rows tall

    private func card(_ capacity: Capacity?) -> some View {
        DashboardCard(icon: "internaldrive.fill", tint: Self.tint, title: title) {
            if let capacity {
                Text(verbatim: capacity.usedPercent)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } content: {
            if let capacity {
                let diameter = min(max(size.height - 18 - 22 - 28, 40), 64)
                Spacer(minLength: 4)
                // Equal gaps before the ring, between ring and text, and after
                // the text, instead of everything piled against the left edge.
                HStack(spacing: 0) {
                    Spacer(minLength: 6)
                    GaugeRing(
                        fraction: capacity.usedFraction,
                        valueText: capacity.usedPercent,
                        label: String(localized: "Used"),
                        tint: Self.tint,
                        diameter: diameter
                    )
                    Spacer(minLength: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.bytes(capacity.free))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text("Free")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(verbatim: String(localized: "of") + " " + Self.bytes(capacity.total))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 6)
                }
                Spacer(minLength: 4)
            } else {
                emptyState
            }
        }
    }

    // MARK: One row tall

    private func strip(_ capacity: Capacity?) -> some View {
        DashboardCardChrome(tint: Self.tint) {
            if let capacity {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        DashboardCardTitle(icon: "internaldrive.fill", tint: Self.tint, title: title)
                        MiniGauge(
                            fraction: capacity.usedFraction,
                            valueText: capacity.usedPercent,
                            label: String(localized: "Used"),
                            tint: Self.tint
                        )
                        Text(verbatim: Self.bytes(capacity.free) + " " + String(localized: "Free"))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxHeight: .infinity)

                    VStack(alignment: .leading, spacing: 7) {
                        DashboardCardTitle(icon: "internaldrive.fill", tint: Self.tint, title: title)
                        Text(verbatim: capacity.usedPercent + " · " + Self.bytes(capacity.free) + " " + String(localized: "Free"))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
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
