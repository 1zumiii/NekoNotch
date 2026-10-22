//
//  BatterySettingsView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import SwiftUI

struct BatterySettingsView: View {
    @Default(.batteryEdgeLine) private var batteryEdgeLine

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showBatteryIndicator) {
                    Text("Show battery indicator")
                }
                Defaults.Toggle(key: .showPowerStatusNotifications) {
                    Text("Show power status notifications")
                }
                Defaults.Toggle(key: .batteryEdgeLine) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show the charge as a line under the closed notch")
                        Text("A thin line along the bottom edge fills from the left with the charge: green while charging, red at 20% or less.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Preview the line")
                    Spacer()
                    Button("Low battery") {
                        BatteryEdgeLinePreview.shared.show(.low)
                    }
                    Button("Charging") {
                        BatteryEdgeLinePreview.shared.show(.charging)
                    }
                }
                .disabled(!batteryEdgeLine)
            } header: {
                Text("General")
            }
            BatteryAlertsSection()

            Section {
                Defaults.Toggle(key: .showBatteryPercentage) {
                    Text("Show battery percentage")
                }
                Defaults.Toggle(key: .showPowerStatusIcons) {
                    Text("Show power status icons")
                }
                Defaults.Toggle(key: .showChargingWattage) {
                    Text("Show charging wattage")
                }
            } header: {
                Text("Battery Information")
            }
        }
        .onAppear {
            Task { @MainActor in
                await XPCHelperClient.shared.isAccessibilityAuthorized()
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Battery")
    }
}

/// Pick the battery levels to be warned at.
private struct BatteryAlertsSection: View {
    @Default(.batteryAlertsEnabled) private var enabled
    @Default(.batteryAlertThresholds) private var thresholds
    @Default(.showPowerStatusNotifications) private var showPowerNotifications
    @State private var customLevel = 15

    private static let presets = [50, 40, 30, 25, 20, 15, 10, 5, 3]

    /// Presets plus any custom levels already chosen, so each can be removed.
    private var chips: [Int] {
        Array(Set(Self.presets).union(thresholds)).sorted(by: >)
    }

    var body: some View {
        Section {
            Defaults.Toggle(key: .batteryAlertsEnabled) {
                Text("Alert at low battery levels")
            }
            .disabled(!showPowerNotifications)

            if enabled && showPowerNotifications {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(chips, id: \.self) { level in
                        chip(level)
                    }
                }
                .padding(.vertical, 2)

                HStack {
                    Stepper(value: $customLevel, in: 1...99) {
                        Text("Add a level: \(customLevel)%")
                    }
                    Button("Add") {
                        if !thresholds.contains(customLevel) { thresholds.append(customLevel) }
                    }
                    .disabled(thresholds.contains(customLevel))
                }

                Button("Preview alert") {
                    BatteryStatusViewModel.shared.previewLowBatteryAlert()
                }
            }
        } header: {
            Text("Battery Alerts")
        } footer: {
            // LocalizedStringKey: a ternary of literals would otherwise pick
            // the verbatim String overload and skip translation.
            Text(LocalizedStringKey(showPowerNotifications
                 ? "Get a message in the notch when the battery drops to each selected level while unplugged. Each level speaks once per discharge and arms again after charging."
                 : "Turn on \"Show power status notifications\" above to use battery alerts."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chip(_ level: Int) -> some View {
        let isOn = thresholds.contains(level)
        return Button {
            if isOn {
                thresholds.removeAll { $0 == level }
            } else {
                thresholds.append(level)
            }
        } label: {
            Text(verbatim: "\(level)%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isOn ? Color.black : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Capsule().fill(isOn ? Color.effectiveAccent : Color.primary.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}
