//
//  DashboardWidgets.swift
//  boringNotch
//
import SwiftUI

/// One thing that can be placed on the dashboard. To add a widget, add an
/// entry to `DashboardWidgets.all`; layout, settings and persistence follow.
struct DashboardWidgetInfo: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let icon: String
    let tint: Color
    let minWidth: Int
    let minHeight: Int
    let maxWidth: Int
    let maxHeight: Int
    let defaultPlacement: DashboardPlacement
    /// Builds the widget for the pixel size of the cells it occupies.
    let content: (CGSize) -> AnyView
}

enum DashboardWidgets {
    static let all: [DashboardWidgetInfo] = usageWidgets + [storageWidget, claudeCodeWidget]

    private static let usageWidgets: [DashboardWidgetInfo] = UsageSource.all.enumerated().map { index, source in
        DashboardWidgetInfo(
            id: source.id,
            title: LocalizedStringKey(source.displayName),
            icon: source.icon,
            tint: source.tint,
            minWidth: 2,
            minHeight: 1,
            maxWidth: 6,
            maxHeight: 2,
            defaultPlacement: DashboardPlacement(
                id: source.id, enabled: true, col: index * 2, row: 0, width: 2, height: 2
            ),
            content: { size in AnyView(UsageWidgetView(source: source, size: size)) }
        )
    }

    private static let storageWidget = DashboardWidgetInfo(
        id: "storage",
        title: "Storage",
        icon: "internaldrive.fill",
        tint: StorageWidgetView.tint,
        minWidth: 2,
        minHeight: 1,
        maxWidth: 6,
        maxHeight: 2,
        defaultPlacement: DashboardPlacement(
            id: "storage", enabled: true, col: UsageSource.all.count * 2, row: 0, width: 2, height: 2
        ),
        content: { size in AnyView(StorageWidgetView(size: size)) }
    )

    private static let claudeCodeWidget = DashboardWidgetInfo(
        id: "claudeCode",
        title: "Claude Code",
        icon: "square.grid.3x3.fill",
        tint: ClaudeCodeStatsWidgetView.tint,
        minWidth: 2,
        minHeight: 1,
        maxWidth: 6,
        maxHeight: 2,
        defaultPlacement: DashboardPlacement(
            id: "claudeCode", enabled: false, col: 0, row: 0, width: 3, height: 2
        ),
        content: { size in AnyView(ClaudeCodeStatsWidgetView(size: size)) }
    )

    static func info(for id: String) -> DashboardWidgetInfo? {
        all.first { $0.id == id }
    }
}
