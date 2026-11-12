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
