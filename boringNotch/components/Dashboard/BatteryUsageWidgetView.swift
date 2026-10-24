//
//  BatteryUsageWidgetView.swift
//  boringNotch
//
import AppKit
import SwiftUI

/// The apps that have used the most energy, each as a share of what all apps
/// have used. The system keeps no history an app can read, so this is the
/// energy each process has used since it started, as the kernel counts it,
/// summed per app the way Activity Monitor does: helpers and command-line
/// tools count toward the app responsible for them (a browser's helpers, a
/// terminal's tools).
struct BatteryUsageEntry: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    /// 0...1 of all apps' energy.
    let share: Double
}

enum BatteryUsageReader {
    /// The top `limit` apps. The sandbox keeps the app from reading other
    /// processes, so the helper reads them (ProcessEnergy there).
    static func read(limit: Int) async -> [BatteryUsageEntry] {
        guard let energy = await XPCHelperClient.shared.processEnergy() else { return [] }
        return await MainActor.run {
            // Only apps a person knows: Dock apps and menu bar apps, not
            // agents and daemons.
            var byApp: [String: (app: NSRunningApplication, energy: UInt64)] = [:]
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
                guard let used = energy[app.processIdentifier] else { continue }
                let key = app.bundleURL?.path ?? app.bundleIdentifier ?? "pid-\(app.processIdentifier)"
                byApp[key, default: (app, 0)].energy += used
            }
            let total = byApp.values.reduce(0) { $0 + $1.energy }
            guard total > 0 else { return [] }
            return byApp
                .sorted { $0.value.energy > $1.value.energy }
                .prefix(limit)
                .map { key, value in
                    BatteryUsageEntry(
                        id: key,
                        name: value.app.localizedName ?? (key as NSString).lastPathComponent,
                        icon: value.app.icon ?? NSWorkspace.shared.icon(forFile: key),
                        share: Double(value.energy) / Double(total)
                    )
                }
        }
    }
}

struct BatteryUsageWidgetView: View {
    static let tint = Color(red: 0.96, green: 0.76, blue: 0.26)

    let size: CGSize

    @State private var entries: [BatteryUsageEntry]?

    private var isStrip: Bool { size.height < 90 }
    private var title: String { String(localized: "Battery Usage") }
    private var subtitle: String { String(localized: "Since launch") }
    private static let icon = "bolt.fill"
    private static let rowHeight: CGFloat = 22
    private static let refreshInterval: Duration = .seconds(10)

    /// As many rows as the card has room for.
    private var rowCount: Int {
        isStrip ? 3 : min(max(Int((size.height - 18 - 30) / Self.rowHeight), 1), 6)
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
        .task(id: rowCount) {
            // Only while the dashboard is on screen; nothing runs in the
            // background.
            while !Task.isCancelled {
                entries = await BatteryUsageReader.read(limit: rowCount)
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private static func percent(_ share: Double) -> String {
        share >= 0.995 ? "100%" : share < 0.01 ? "<1%" : "\(Int((share * 100).rounded()))%"
    }

    // MARK: Two rows tall

    private var card: some View {
        DashboardCard(icon: Self.icon, tint: Self.tint, title: title, subtitle: subtitle) {
            EmptyView()
        } content: {
            if let entries, !entries.isEmpty {
                // Bars are scaled to the top app, so the ranking reads at a
                // glance even when every share is small.
                let top = entries.first?.share ?? 1
                Spacer(minLength: 4)
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        row(entry, relative: top > 0 ? entry.share / top : 0)
                            .frame(height: Self.rowHeight)
                    }
                }
                Spacer(minLength: 0)
            } else {
                emptyState
            }
        }
    }

    private func row(_ entry: BatteryUsageEntry, relative: Double) -> some View {
        HStack(spacing: 7) {
            Image(nsImage: entry.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(verbatim: entry.name)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(verbatim: Self.percent(entry.share))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(Self.tint)
                            .frame(width: max(proxy.size.width * relative, 3))
                    }
                }
                .frame(height: 3)
            }
        }
    }

    // MARK: One row tall

    private var strip: some View {
        DashboardCardChrome(tint: Self.tint) {
            if let entries, !entries.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        DashboardCardTitle(icon: Self.icon, tint: Self.tint, title: title, subtitle: subtitle)
                        chips(entries)
                    }
                    .frame(maxHeight: .infinity)

                    VStack(alignment: .leading, spacing: 7) {
                        DashboardCardTitle(icon: Self.icon, tint: Self.tint, title: title)
                        chips(entries)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            } else {
                emptyState
            }
        }
    }

    private func chips(_ entries: [BatteryUsageEntry]) -> some View {
        HStack(spacing: 10) {
            ForEach(entries) { entry in
                HStack(spacing: 4) {
                    Image(nsImage: entry.icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                    Text(verbatim: Self.percent(entry.share))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .help(entry.name)
                .fixedSize()
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
