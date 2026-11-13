//
//  OSDKeys.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import Defaults

// Volume, brightness and keyboard OSD.
extension Defaults.Keys {
    static let osdReplacement = Key<Bool>(PreferenceCompatibility.migratedKeyName("osdReplacement", from: "hudReplacement"), default: true)
    static let inlineOSD = Key<Bool>(PreferenceCompatibility.migratedKeyName("inlineOSD", from: "inlineHUD"), default: false)
    static let enableGradient = Key<Bool>("enableGradient", default: true)
    static let systemEventIndicatorShadow = Key<Bool>("systemEventIndicatorShadow", default: false)
    static let systemEventIndicatorUseAccent = Key<Bool>("systemEventIndicatorUseAccent", default: false)
    static let showOpenNotchOSD = Key<Bool>(PreferenceCompatibility.migratedKeyName("showOpenNotchOSD", from: "showOpenNotchHUD"), default: true)
    static let showOpenNotchOSDPercentage = Key<Bool>(PreferenceCompatibility.migratedKeyName("showOpenNotchOSDPercentage", from: "showOpenNotchHUDPercentage"), default: true)
    static let showClosedNotchOSDPercentage = Key<Bool>(PreferenceCompatibility.migratedKeyName("showClosedNotchOSDPercentage", from: "showClosedNotchHUDPercentage"), default: false)

    // Option key modifier behaviour for media keys
    static let optionKeyAction = Key<OptionKeyAction>("optionKeyAction", default: OptionKeyAction.openSettings)

    // Brightness/volume/keyboard source selection
    static let osdBrightnessSource = Key<OSDControlSource>("osdBrightnessSource", default: .builtin)
    static let osdVolumeSource = Key<OSDControlSource>("osdVolumeSource", default: .builtin)
}
