//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var shelfState = ShelfStateViewModel.shared
    var body: some View {
        GeometryReader { geometry in
            // Equal, explicitly bounded wings keep the reserved hardware area
            // centred even when one side has more controls than the other.
            let centreWidth = vm.notchState == .open ? vm.closedNotchSize.width : 0
            let sideWidth = max(0, (geometry.size.width - centreWidth) / 2)
            HStack(spacing: 0) {
                HStack {
                    if !shelfState.isEmpty || coordinator.alwaysShowTabs {
                        TabSelectionView()
                    } else if vm.notchState == .open {
                        EmptyView()
                    }
                }
                .padding(.trailing, vm.notchState == .open ? 8 : 0)
                .frame(width: sideWidth, height: geometry.size.height, alignment: .leading)
                // Not clipped: the tab strip already sizes itself to the wing,
                // and a clip here lags the first frames of opening, cropping
                // the strip's backdrop to a stale rectangle.
                .opacity(vm.notchState == .closed ? 0 : 1)
                .blur(radius: vm.notchState == .closed ? 20 : 0)
                .zIndex(2)

                if vm.notchState == .open {
                    Rectangle()
                        .fill(vm.hasNotch ? .black : .clear)
                        .frame(width: centreWidth)
                        .mask {
                            NotchShape()
                        }
                }

                HStack(spacing: 4) {
                    if vm.notchState == .open {
                        if isOSDType(coordinator.sneakPeekState(for: vm.screenUUID).type) && coordinator.shouldShowSneakPeek(on: vm.screenUUID) && Defaults[.showOpenNotchOSD] {
                            OpenNotchOSD(
                                 type: coordinator.binding(for: vm.screenUUID).type,
                                 value: coordinator.binding(for: vm.screenUUID).value,
                                 icon: coordinator.binding(for: vm.screenUUID).icon,
                                 accent: coordinator.binding(for: vm.screenUUID).accent
                            )
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        } else {
                            if Defaults[.showMirror] && coordinator.currentView == .home {
                                Button(action: {
                                    vm.toggleCameraPreview()
                                }) {
                                    Capsule()
                                        .fill(.black)
                                        .frame(width: 30, height: 30)
                                        .overlay {
                                            Image(systemName: "web.camera")
                                                .foregroundColor(.white)
                                                .padding()
                                                .imageScale(.medium)
                                        }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            if Defaults[.settingsIconInNotch] {
                                Button(action: {
                                    DispatchQueue.main.async {
                                        SettingsWindowController.shared.showWindow()
                                    }
                                }) {
                                    Capsule()
                                        .fill(.black)
                                        .frame(width: 30, height: 30)
                                        .overlay {
                                            Image(systemName: "gear")
                                                .foregroundColor(.white)
                                                .padding()
                                                .imageScale(.medium)
                                        }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            if Defaults[.showBatteryIndicator] {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    maxCapacity: batteryModel.maxCapacity,
                                    timeToFullCharge: batteryModel.timeToFullCharge,
                                    timeToDischarge: batteryModel.timeToDischarge,
                                    maxAdapterWatts: batteryModel.maxAdapterWatts,
                                    isForNotification: false
                                )
                            }
                        }
                    }
                }
                .font(.system(.headline, design: .rounded))
                .padding(.leading, vm.notchState == .open ? 8 : 0)
                .frame(width: sideWidth, height: geometry.size.height, alignment: .trailing)
                .clipped()
                .opacity(vm.notchState == .closed ? 0 : 1)
                .blur(radius: vm.notchState == .closed ? 20 : 0)
                .zIndex(2)
            }
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    func isOSDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel(camera: CameraModel()))
}
