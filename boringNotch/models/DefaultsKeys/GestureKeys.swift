//
//  GestureKeys.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import Defaults

// Gestures.
extension Defaults.Keys {
    static let enableGestures = Key<Bool>("enableGestures", default: true)
    static let enableHorizontalMediaGestures = Key<Bool>("enableHorizontalMediaGestures", default: false)
    static let closeGestureEnabled = Key<Bool>("closeGestureEnabled", default: false)
    static let gestureSensitivity = Key<CGFloat>("gestureSensitivity", default: 200.0)

    // Normalize scroll/gesture direction so when macOS "Natural scrolling" is disabled, it doesn't invert gestures
    static let normalizeGestureDirection = Key<Bool>("normalizeGestureDirection", default: false)
}
