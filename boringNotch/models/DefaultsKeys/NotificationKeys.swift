//
//  NotificationKeys.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import Defaults

// Mirrored system notifications.
extension Defaults.Keys {
    /// Off by default: mirroring banners needs Accessibility access.
    static let notificationLiveActivity = Key<Bool>("notificationLiveActivity", default: true)
    static let notificationsFromAllApps = Key<Bool>("notificationsFromAllApps", default: true)

    /// Open the notch on its own when a notification arrives, instead of
    /// waiting for the pointer.
    static let notificationAutoExpand = Key<Bool>("notificationAutoExpand", default: true)

    /// Read notifications from Notification Center's database (Full Disk
    /// Access) so system banners can be switched off instead of hidden.
    static let notificationFromDatabase = Key<Bool>("notificationFromDatabase", default: true)

    /// For apps whose banners are off, show the app the moment its notification
    /// arrives and fill in the text when the database delivers it.
    static let notificationEarlyPlaceholder = Key<Bool>("notificationEarlyPlaceholder", default: true)

    /// Give time-sensitive notifications a rainbow outline, a longer stay, and
    /// priority over ordinary ones (the database reader supplies the level).
    static let notificationPriorityHighlight = Key<Bool>("notificationPriorityHighlight", default: true)

    /// Seconds a mirrored notification stays before it is dismissed.
    static let notificationDisplayDuration = Key<Double>("notificationDisplayDuration", default: 4)

    /// Apps whose notifications are left to the system: not mirrored, and
    /// their banners are not hidden. Lower-cased bundle identifiers.
    static let notificationExcludedApps = Key<Set<String>>("notificationExcludedApps", default: [])

    /// Apps whose notifications only show their icon on the left of the closed
    /// notch, in place of the album art while music plays. Lower-cased bundle identifiers.
    static let notificationIconOnlyApps = Key<Set<String>>("notificationIconOnlyApps", default: [])

    /// Seconds an icon-only notification stays before it goes.
    static let notificationIconOnlyDuration = Key<Double>("notificationIconOnlyDuration", default: 4)

    /// Keep the notifications that arrived, in memory only, for the
    /// dashboard's history card. Cleared on quit.
    static let notificationHistory = Key<Bool>("notificationHistory", default: true)

    /// What the notch shows while a Focus is on.
    static let notificationFocusBehavior = Key<FocusNotificationBehavior>("notificationFocusBehavior", default: .follow)

    /// The apps that notified most recently, newest first, as "bundle id|name",
    /// so they can be excluded from the settings without having an .app.
    static let notificationRecentSources = Key<[String]>("notificationRecentSources", default: [])
    static let notificationAllowedApps = Key<Set<String>>(
        "notificationAllowedApps",
        default: []
    )
}
