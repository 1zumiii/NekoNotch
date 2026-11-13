//
//  BatteryKeys.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import Defaults

// Battery.
extension Defaults.Keys {
    static let showPowerStatusNotifications = Key<Bool>("showPowerStatusNotifications", default: true)

    /// Announce in the notch when the battery drops to each chosen level.
    /// A thin line along the bottom of the closed notch that shows the charge.
    static let batteryEdgeLine = Key<Bool>("batteryEdgeLine", default: true)
    static let batteryAlertsEnabled = Key<Bool>("batteryAlertsEnabled", default: true)
    static let batteryAlertThresholds = Key<[Int]>("batteryAlertThresholds", default: [50, 30, 20, 10])
    static let showBatteryIndicator = Key<Bool>("showBatteryIndicator", default: true)
    static let showBatteryPercentage = Key<Bool>("showBatteryPercentage", default: true)
    static let showPowerStatusIcons = Key<Bool>("showPowerStatusIcons", default: true)
    static let showChargingWattage = Key<Bool>("showChargingWattage", default: true)
}
