//
//  NotificationHistory.swift
//  boringNotch
//
import Combine
import Defaults
import Foundation

struct NotificationHistoryEntry: Identifiable, Equatable {
    let id = UUID()
    let notification: SystemNotification
    /// Kept out of the notch by a Focus; this is the only place it shows.
    let silenced: Bool
}

/// The notifications that reached the notch, newest first, so one that went
/// by unseen can still be found. In memory only: nothing is written to disk,
/// and quitting the app clears it.
@MainActor
final class NotificationHistory: ObservableObject {
    static let shared = NotificationHistory()

    @Published private(set) var entries: [NotificationHistoryEntry] = []
    /// Arrived since the notifications tab was last open, for the dot on its icon.
    @Published private(set) var unseenCount = 0
    /// The tab is on screen: what arrives now is seen as it arrives.
    var isViewing = false {
        didSet { if isViewing { unseenCount = 0 } }
    }

    static let limit = 50
    /// The banner reader and the database can both deliver the same
    /// notification, seconds apart.
    private static let duplicateWindow: TimeInterval = 15

    private init() {}

    func record(_ notification: SystemNotification, silenced: Bool = false) {
        guard Defaults[.notificationHistory], !notification.isPlaceholder else { return }
        let key = SystemNotificationManager.dedupeKey(notification)
        let isDuplicate = entries.contains { entry in
            abs(entry.notification.receivedAt.timeIntervalSince(notification.receivedAt)) < Self.duplicateWindow
                && entry.notification.bundleID == notification.bundleID
                && SystemNotificationManager.dedupeKey(entry.notification) == key
                // Two database records are two notifications, however alike their text.
                && !Self.areDifferentRecords(entry.notification, notification)
        }
        guard !isDuplicate else { return }
        entries.insert(NotificationHistoryEntry(notification: notification, silenced: silenced), at: 0)
        if !isViewing { unseenCount += 1 }
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
    }

    private static func areDifferentRecords(_ a: SystemNotification, _ b: SystemNotification) -> Bool {
        guard let first = a.recordUUID, let second = b.recordUUID else { return false }
        return first != second
    }

    func remove(_ entry: NotificationHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
    }

    func clear() {
        entries.removeAll()
        unseenCount = 0
    }
}
