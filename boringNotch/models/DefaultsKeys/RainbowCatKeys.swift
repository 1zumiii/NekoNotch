//
//  RainbowCatKeys.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import Defaults

// The rainbow cat.
extension Defaults.Keys {
    /// A pixel cat runs on the right of the closed notch, faster as the CPU gets busier.
    static let rainbowCat = Key<Bool>("rainbowCat", default: true)

    /// While media plays, the cat takes the waveform's place and its trail moves with the audio.
    static let rainbowCatInPlayer = Key<Bool>("rainbowCatInPlayer", default: true)

    /// Hovering over the cat opens the system monitor instead of the usual tabs.
    static let rainbowCatSystemMonitor = Key<Bool>("rainbowCatSystemMonitor", default: true)

    /// The empty wing left of the cutout folds away when the pointer comes
    /// over it and it covers the frontmost app's menus, so the last of them
    /// can be clicked.
    static let rainbowCatMenuAvoidance = Key<Bool>("rainbowCatMenuAvoidance", default: true)

    /// How many times as fast the cat runs at full CPU load as at rest.
    static let rainbowCatMaxSpeed = Key<Double>("rainbowCatMaxSpeed", default: 3)

    /// How many times as fast the stars drift at full CPU load as at rest.
    static let rainbowCatSkyMaxSpeed = Key<Double>("rainbowCatSkyMaxSpeed", default: 4)

    /// Past `rainbowCatWarpThreshold` CPU load, the stars turn into streaks of light.
    static let rainbowCatWarp = Key<Bool>("rainbowCatWarp", default: true)
    static let rainbowCatWarpThreshold = Key<Double>("rainbowCatWarpThreshold", default: 0.7)
}
