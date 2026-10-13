//
//  BatteryAlertTracker.swift
//  boringNotch
//

import Foundation

/// Decides when a battery-level alert should be announced.
///
/// The rules are chosen so a level that wobbles around a threshold, a jump
/// across several thresholds, or a plug/unplug at an awkward level can never
/// produce a burst of alerts:
/// - A threshold is *armed* while the level is above it. It fires once, when
///   the level reaches or drops below it while running on battery, and is then
///   disarmed.
/// - A disarmed threshold re-arms only after the level climbs `hysteresis`
///   points above it, or when the charger is connected and the level is above
///   it. Wobbling between 20 and 21 therefore fires once, not repeatedly.
/// - If one change crosses several thresholds (a big drop, or waking from
///   sleep), only the lowest one is announced; the others are disarmed too.
/// - Nothing is announced while on AC power, nor for thresholds the level was
///   already below when the app started or when the threshold was added.
struct BatteryAlertTracker {
    static let hysteresis = 3

    private var armed = Set<Int>()
    private var known = Set<Int>()

    /// - Parameters:
    ///   - level: battery percentage, 0...100
    ///   - onBattery: true when running on battery (not plugged in)
    ///   - thresholds: the levels the user wants alerts at
    /// - Returns: the threshold to announce now, if any
    mutating func update(level: Int, onBattery: Bool, thresholds: Set<Int>) -> Int? {
        // Forget removed thresholds.
        armed.formIntersection(thresholds)
        known.formIntersection(thresholds)

        // A threshold seen for the first time (startup, or the user just added
        // it) is armed only if the level is still above it: no instant alert
        // for a line that has already been crossed.
        for threshold in thresholds.subtracting(known) where level > threshold {
            armed.insert(threshold)
        }
        known.formUnion(thresholds)

        // Re-arm.
        for threshold in thresholds where !armed.contains(threshold) {
            let climbed = level >= threshold + Self.hysteresis
            let charging = !onBattery && level > threshold
            if climbed || charging { armed.insert(threshold) }
        }

        guard onBattery else { return nil }

        let crossed = armed.filter { level <= $0 }
        guard let lowest = crossed.min() else { return nil }
        armed.subtract(crossed)
        return lowest
    }
}
