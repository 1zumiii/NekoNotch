//
//  DashboardSettingsView.swift
//  boringNotch
//
import Defaults
import SwiftUI

/// Settings page for the dashboard: a live preview of the grid, and controls
/// that move and resize widgets one cell at a time. Changes that would leave
/// the grid or overlap another widget are simply unavailable.
struct DashboardSettingsView: View {
    @Default(.dashboardLayout) private var storedLayout
    @State private var selection: String?
    @State private var message: LocalizedStringKey?

    private var layout: [DashboardPlacement] { DashboardLayout.normalized(storedLayout) }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showDashboardTab) {
                    Text("Show dashboard tab")
                }
            }

            Section {
                preview
                if let selected = selectedPlacement, selected.enabled {
                    controls(for: selected)
                }
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Layout")
            } footer: {
                Text("Click a widget in the preview to select it, then move or resize it one cell at a time. Click an empty cell to move the selected widget there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(DashboardWidgets.all) { info in
                    widgetRow(info)
                }
            } header: {
                Text("Widgets")
            }

            Section {
                Button("Reset layout") {
                    storedLayout = DashboardLayout.defaults
                    selection = nil
                    message = nil
                }
            }
        }
        .formStyle(.grouped)
        .accentColor(.effectiveAccent)
        .navigationTitle("Dashboard")
    }

    private var selectedPlacement: DashboardPlacement? {
        layout.first { $0.id == selection }
    }

    // MARK: Preview

    private var preview: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 4
            let columns = CGFloat(DashboardGrid.columns)
            let rows = CGFloat(DashboardGrid.rows)
            let cellWidth = (proxy.size.width - gap * (columns - 1)) / columns
            let cellHeight = (proxy.size.height - gap * (rows - 1)) / rows

            ZStack(alignment: .topLeading) {
                ForEach(0..<DashboardGrid.rows, id: \.self) { row in
                    ForEach(0..<DashboardGrid.columns, id: \.self) { col in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: cellWidth, height: cellHeight)
                            .offset(x: CGFloat(col) * (cellWidth + gap), y: CGFloat(row) * (cellHeight + gap))
                            .onTapGesture { moveSelected(toCol: col, row: row) }
                    }
                }
                ForEach(layout.filter(\.enabled)) { placement in
                    if let info = DashboardWidgets.info(for: placement.id) {
                        let isSelected = placement.id == selection
                        RoundedRectangle(cornerRadius: 8)
                            .fill(info.tint.opacity(isSelected ? 0.55 : 0.35))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isSelected ? Color.primary.opacity(0.8) : .clear, lineWidth: 2)
                            }
                            .overlay {
                                VStack(spacing: 2) {
                                    Image(systemName: info.icon)
                                    Text(info.title).font(.caption).lineLimit(1)
                                    Text(verbatim: "\(placement.width)×\(placement.height)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(
                                width: CGFloat(placement.width) * cellWidth + CGFloat(placement.width - 1) * gap,
                                height: CGFloat(placement.height) * cellHeight + CGFloat(placement.height - 1) * gap
                            )
                            .offset(
                                x: CGFloat(placement.col) * (cellWidth + gap),
                                y: CGFloat(placement.row) * (cellHeight + gap)
                            )
                            .onTapGesture { selection = placement.id; message = nil }
                    }
                }
            }
        }
        .frame(height: 120)
        .padding(.vertical, 4)
    }

    // MARK: Controls

    private func controls(for placement: DashboardPlacement) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Text("Position").frame(width: 70, alignment: .leading)
                stepButton("arrow.left", placement) { $0.col -= 1 }
                stepButton("arrow.right", placement) { $0.col += 1 }
                stepButton("arrow.up", placement) { $0.row -= 1 }
                stepButton("arrow.down", placement) { $0.row += 1 }
            }
            HStack(spacing: 16) {
                Text("Width").frame(width: 70, alignment: .leading)
                stepButton("minus", placement) { $0.width -= 1 }
                Text(verbatim: "\(placement.width)").monospacedDigit().frame(width: 20)
                stepButton("plus", placement) { $0.width += 1 }
            }
            HStack(spacing: 16) {
                Text("Height").frame(width: 70, alignment: .leading)
                stepButton("minus", placement) { $0.height -= 1 }
                Text(verbatim: "\(placement.height)").monospacedDigit().frame(width: 20)
                stepButton("plus", placement) { $0.height += 1 }
            }
        }
    }

    private func stepButton(
        _ symbol: String,
        _ placement: DashboardPlacement,
        _ change: @escaping (inout DashboardPlacement) -> Void
    ) -> some View {
        var candidate = placement
        change(&candidate)
        let allowed = DashboardLayout.isValid(candidate, among: layout)
        return Button {
            apply(candidate)
        } label: {
            Image(systemName: symbol).frame(width: 20)
        }
        .disabled(!allowed)
    }

    // MARK: Widget list

    private func widgetRow(_ info: DashboardWidgetInfo) -> some View {
        let placement = layout.first { $0.id == info.id } ?? info.defaultPlacement
        return HStack {
            Image(systemName: info.icon)
                .foregroundStyle(info.tint)
                .frame(width: 20)
            Text(info.title)
            Spacer()
            Toggle("", isOn: Binding(
                get: { placement.enabled },
                set: { setEnabled($0, for: info) }
            ))
            .labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture { if placement.enabled { selection = info.id; message = nil } }
    }

    // MARK: Changes

    private func apply(_ placement: DashboardPlacement) {
        var all = layout
        guard let index = all.firstIndex(where: { $0.id == placement.id }),
              DashboardLayout.isValid(placement, among: all) else { return }
        all[index] = placement
        storedLayout = all
        message = nil
    }

    private func moveSelected(toCol col: Int, row: Int) {
        guard var placement = selectedPlacement, placement.enabled else { return }
        placement.col = min(col, DashboardGrid.columns - placement.width)
        placement.row = min(row, DashboardGrid.rows - placement.height)
        apply(placement)
    }

    private func setEnabled(_ enabled: Bool, for info: DashboardWidgetInfo) {
        var all = layout
        guard let index = all.firstIndex(where: { $0.id == info.id }) else { return }
        if !enabled {
            all[index].enabled = false
            storedLayout = all
            if selection == info.id { selection = nil }
            return
        }

        // Try its current size, then its smallest, in the first free spot.
        var attempt = all[index]
        var smallest = attempt
        smallest.width = info.minWidth
        smallest.height = info.minHeight
        for candidate in [attempt, smallest] {
            if let placed = DashboardLayout.firstFreeSpot(for: candidate, among: all) {
                attempt = placed
                all[index] = attempt
                storedLayout = all
                selection = info.id
                message = nil
                return
            }
        }
        message = "No free space on the grid. Shrink or turn off another widget first."
    }
}
