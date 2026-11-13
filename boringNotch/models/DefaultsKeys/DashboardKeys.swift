//
//  DashboardKeys.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import Defaults

// Dashboard.
extension Defaults.Keys {
    static let showDashboardTab = Key<Bool>("showDashboardTab", default: true)

    /// Grid placement of each dashboard widget. See DashboardLayout.
    static let dashboardLayout = Key<[DashboardPlacement]>("dashboardLayout", default: DashboardLayout.defaults)

    /// The grid `dashboardLayout` was saved in; see DashboardLayout.migrateIfNeeded.
    static let dashboardLayoutVersion = Key<Int>("dashboardLayoutVersion", default: 1)
}
