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
    // Storage, battery usage and system load moved to the rainbow cat's system monitor.
    // Codex is a tab of the quota card; its own widget (id "codex") is gone and
    // DashboardLayout.normalized drops it from saved layouts.
    static let all: [DashboardWidgetInfo] = [quotaWidget, claudeCodeWidget]

    /// Keeps the id "claude" so saved layouts keep its place and size.
    private static let quotaWidget = DashboardWidgetInfo(
        id: UsageSource.claude.id,
        title: "AI Quota",
        icon: UsageSource.claude.icon,
        tint: UsageSource.claude.tint,
        minWidth: 4,
        minHeight: 2,
        maxWidth: 12,
        maxHeight: 4,
        defaultPlacement: DashboardPlacement(
            id: UsageSource.claude.id, enabled: true, col: 0, row: 0, width: 4, height: 4
        ),
        content: { size in AnyView(UsageWidgetView(source: .claude, size: size)) }
    )

    private static let claudeCodeWidget = DashboardWidgetInfo(
        id: "claudeCode",
        title: "AI Tokens",
        icon: "square.grid.3x3.fill",
        tint: ClaudeCodeStatsWidgetView.tint,
        minWidth: 4,
        minHeight: 2,
        maxWidth: 12,
        maxHeight: 4,
        defaultPlacement: DashboardPlacement(
            id: "claudeCode", enabled: false, col: 0, row: 0, width: 6, height: 4
        ),
        content: { size in AnyView(ClaudeCodeStatsWidgetView(size: size)) }
    )

    static func info(for id: String) -> DashboardWidgetInfo? {
        all.first { $0.id == id }
    }
}
