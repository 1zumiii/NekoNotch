import Cocoa
import Defaults
import Foundation
import IOKit.ps
import SwiftUI

/// A view model that manages and monitors the battery status of the device
final class BatteryStatusViewModel: ObservableObject {
    private var wasCharging: Bool = false
    private var notifyTask: Task<Void, Never>?
    private var lastPowerSourceChange = Date.distantPast
    private static let coalesceInterval: Double = 0.25
    /// A charging-state change this soon after plugging/unplugging is part of
    /// the same event, not news of its own.
    private static let followUpWindow: TimeInterval = 2
    private var powerSourceChangedCallback: IOPowerSourceCallbackType?
    private var runLoopSource: Unmanaged<CFRunLoopSource>?

    @Published private(set) var levelBattery: Float = 0.0
    @Published private(set) var maxCapacity: Float?
    @Published private(set) var isPluggedIn: Bool = false
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var isInLowPowerMode: Bool = false
    @Published private(set) var isInitial: Bool = false
    @Published private(set) var timeToFullCharge: Int = 0
    @Published private(set) var timeToDischarge: Int = 0
    @Published private(set) var maxAdapterWatts: Int = 0
    @Published private(set) var lastStatus: LastStatus = .plugged(false)

    enum LastStatus: Equatable {
        case plugged(Bool)
        case lowPower(Bool)
        case charging(isCharging: Bool, level: Float)
    }

    var statusText: LocalizedStringKey {
        switch lastStatus {
        case .plugged(let plugged):
            return LocalizedStringKey(plugged ? "Plugged In" : "Unplugged")
        case .lowPower(let enabled):
            let key = enabled ? "Low Power: On" : "Low Power: Off"
            return LocalizedStringKey(key)
        case .charging(let isCharging, let level):
            if isCharging {
                return LocalizedStringKey("Charging battery")
            }
            if level < 100 {
                return LocalizedStringKey("Not charging")
            }
            return LocalizedStringKey("Full charge")
        }
    }

    private let managerBattery = BatteryActivityManager.shared
    private var managerBatteryId: Int?

    static let shared = BatteryStatusViewModel()

    /// Initializes the view model with a given BoringViewModel instance
    /// - Parameter vm: The BoringViewModel instance
    private init() {
        setupPowerStatus()
        setupMonitor()
    }

    /// Sets up the initial power status by fetching battery information
    private func setupPowerStatus() {
        let batteryInfo = managerBattery.initializeBatteryInfo()
        updateBatteryInfo(batteryInfo)
    }

    /// Sets up the monitor to observe battery events
    private func setupMonitor() {
        managerBatteryId = managerBattery.addObserver { [weak self] event in
            guard let self = self else { return }
            self.handleBatteryEvent(event)
        }
    }

    /// Handles battery events and updates the corresponding properties
    /// - Parameter event: The battery event to handle
    private func handleBatteryEvent(_ event: BatteryActivityManager.BatteryEvent) {
        switch event {
        case .powerSourceChanged(let isPluggedIn):
            Log.battery.debug("🔌 Power source: \(isPluggedIn ? "Connected" : "Disconnected")")
            withAnimation {
                self.isPluggedIn = isPluggedIn
                self.lastPowerSourceChange = Date()
                // remember the last battery-related message so the computed
                // property can translate it later
                self.lastStatus = .plugged(isPluggedIn)
                self.notifyImportanChangeStatus()
            }

        case .batteryLevelChanged(let level):
            Log.battery.debug("🔋 Battery level: \(Int(level))%")
            withAnimation {
                self.levelBattery = level
            }

        case .lowPowerModeChanged(let isEnabled):
            Log.battery.debug("⚡ Low power mode: \(isEnabled ? "Enabled" : "Disabled")")
            self.notifyImportanChangeStatus()
            withAnimation {
                self.isInLowPowerMode = isEnabled
                self.lastStatus = .lowPower(isEnabled)
            }

        case .isChargingChanged(let isCharging):
            Log.battery.debug("🔌 Charging: \(isCharging ? "Yes" : "No")")
            Log.battery.debug("maxCapacity: \(self.maxCapacity.map { "\($0)" } ?? "Unavailable")")
            Log.battery.debug("levelBattery: \(self.levelBattery)")
            if !isCharging, Date().timeIntervalSince(lastPowerSourceChange) < Self.followUpWindow {
                // "Not charging" right after "Unplugged" says the same thing
                // twice: keep the unplug message, just record the state.
                withAnimation { self.isCharging = isCharging }
            } else {
                self.notifyImportanChangeStatus()
                withAnimation {
                    self.isCharging = isCharging
                    self.lastStatus = .charging(isCharging: isCharging, level: self.levelBattery)
                }
            }

        case .timeToFullChargeChanged(let time):
            Log.battery.debug("🕒 Time to full charge: \(time) minutes")
            withAnimation {
                self.timeToFullCharge = time
            }

        case .timeToDischargeChanged(let time):
            Log.battery.debug("🕒 Time until empty: \(time) minutes")
            withAnimation {
                self.timeToDischarge = time
            }

        case .maxCapacityChanged(let capacity):
            Log.battery.debug("🔋 Max capacity: \(capacity.map { "\($0)" } ?? "Unavailable")")
            withAnimation {
                self.maxCapacity = capacity
            }

        case .adapterWattageChanged(let watts):
            Log.battery.debug("🔌 Power adapter: \(watts)W")
            withAnimation {
                self.maxAdapterWatts = watts
            }

        case .error(let description):
            Log.battery.error("⚠️ Error: \(description)")
        }
    }

    /// Updates the battery information with the given BatteryInfo instance
    /// - Parameter batteryInfo: The BatteryInfo instance containing the battery data
    private func updateBatteryInfo(_ batteryInfo: BatteryInfo) {
        withAnimation {
            self.levelBattery = batteryInfo.currentCapacity
            self.isPluggedIn = batteryInfo.isPluggedIn
            self.isCharging = batteryInfo.isCharging
            self.isInLowPowerMode = batteryInfo.isInLowPowerMode
            self.timeToFullCharge = batteryInfo.timeToFullCharge
            self.timeToDischarge = batteryInfo.timeToDischarge
            self.maxCapacity = batteryInfo.maxCapacity
            self.maxAdapterWatts = batteryInfo.maxAdapterWatts
            self.lastStatus = .plugged(batteryInfo.isPluggedIn)
        }
    }

    /// Notifies important changes in the battery status with an optional delay
    /// - Parameter delay: The delay before notifying the change, default is 0.0
    private func notifyImportanChangeStatus(delay: Double = 0.0) {
        // Unplugging fires several events in a row (power source, then charging
        // state). Each used to pop its own notification, the second replacing
        // the first. Restarting one short timer per event shows a single
        // notification, with whatever status was set last.
        notifyTask?.cancel()
        notifyTask = Task { [delay] in
            try? await Task.sleep(for: .seconds(max(delay, Self.coalesceInterval)))
            guard !Task.isCancelled else { return }
            NotchUIEventBus.events.send(.expandingView(type: .battery))
        }
    }

    deinit {
        Log.battery.debug("🔌 Cleaning up battery monitoring...")
        if let managerBatteryId: Int = managerBatteryId {
            managerBattery.removeObserver(byId: managerBatteryId)
        }
    }
}
