//
//  DashboardView.swift
//  boringNotch
//
import Defaults
import SwiftUI

/// The dashboard tab: widgets placed on a fixed grid of cells.
struct DashboardView: View {
    @Default(.dashboardLayout) private var storedLayout
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    var body: some View {
        GeometryReader { proxy in
            let gap = DashboardGrid.spacing
            let columns = CGFloat(DashboardGrid.columns)
            let rows = CGFloat(DashboardGrid.rows)
            let cellWidth = (proxy.size.width - gap * (columns - 1)) / columns
            let cellHeight = (proxy.size.height - gap * (rows - 1)) / rows
            let placements = DashboardLayout.normalized(storedLayout).filter(\.enabled)

            if placements.isEmpty {
                Text("No widgets enabled")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .topLeading) {
                    ForEach(placements) { placement in
                        if let info = DashboardWidgets.info(for: placement.id) {
                            let size = CGSize(
                                width: CGFloat(placement.width) * cellWidth + CGFloat(placement.width - 1) * gap,
                                height: CGFloat(placement.height) * cellHeight + CGFloat(placement.height - 1) * gap
                            )
                            info.content(size)
                                .frame(width: size.width, height: size.height)
                                .offset(
                                    x: CGFloat(placement.col) * (cellWidth + gap),
                                    y: CGFloat(placement.row) * (cellHeight + gap)
                                )
                        }
                    }
                }
            }
        }
        .padding(.bottom, 2)
        .onAppear {
            // The tab can be switched off while it is the remembered one.
            if !Defaults[.showDashboardTab] { coordinator.currentView = .home }
        }
    }
}
