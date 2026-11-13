//
//  GeneralKeys.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import Defaults

// General settings.
extension Defaults.Keys {
    static let appLanguage = Key<AppLanguage>("appLanguage", default: .system)
    static let menubarIcon = Key<Bool>("menubarIcon", default: true)
    static let displayMode = Key<DisplayMode>("displayMode", default: .fallbackIfPreferredUnavailable)

    // Legacy display settings retained only for one-time migration.
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: true)
    static let followActiveDisplay = Key<Bool>("followActiveDisplay", default: false)
    static let releaseName = Key<String>("releaseName", default: "Dapper Crab 🎩🦀")
}
