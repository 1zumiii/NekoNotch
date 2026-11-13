//
//  SystemNotificationManagerTests.swift
//  boringNotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import XCTest
@testable import boringNotch

/// Waits that end only when a test says so. Every wait the manager starts
/// is recorded with its length, so a test can check how long something was
/// meant to stay and then let that time pass.
@MainActor
final class ManualSleeper {
    private var pending: [(duration: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []
    /// Every wait asked for, in order.
    private(set) var requested: [TimeInterval] = []

    func sleep(_ duration: TimeInterval) async {
        await withCheckedContinuation { continuation in
            requested.append(duration)
            pending.append((duration, continuation))
        }
    }

    /// Ends every pending wait of this length, then lets the woken tasks run.
    func elapse(_ duration: TimeInterval) async {
        // Tasks just created have not reached their wait yet.
        await settle()
        let ending = pending.filter { $0.duration == duration }
        pending.removeAll { $0.duration == duration }
        ending.forEach { $0.continuation.resume() }
        await settle()
    }

    /// Ends every pending wait, so no task is left suspended after a test.
    func finish() {
        pending.forEach { $0.continuation.resume() }
        pending.removeAll()
    }
}

/// Lets tasks started on the main actor run up to their next wait.
@MainActor
func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

/// A manager with every dependency replaced: a fixed clock, settings of the
/// test's own (never the user's), and waits the test ends itself.
@MainActor
final class NotificationHarness {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var settings = SystemNotificationManager.Settings()
    var isFocused = false
    var hidesNotch = false
    private(set) var history: [(notification: SystemNotification, silenced: Bool)] = []
    let sleeper = ManualSleeper()

    lazy var manager = SystemNotificationManager(
        environment: SystemNotificationManager.Environment(
            now: { [unowned self] in now },
            settings: { [unowned self] in settings },
            isFocused: { [unowned self] in isFocused },
            hidesNotchForFullScreen: { [unowned self] in hidesNotch },
            sleep: { [sleeper] in await sleeper.sleep($0) },
            isLaunchable: { _ in true },
            bundleIDForAppNamed: { _ in nil },
            appInfo: { id in (id, String(id.split(separator: ".").last ?? Substring(id))) },
            recordHistory: { [unowned self] in history.append(($0, $1)) },
            noteSource: { _, _ in }
        ),
        observesSystem: false
    )

    var active: SystemNotification? { manager.activeNotification }
    var queuedIDs: [String] { manager.queuedNotifications.map(\.id) }

    /// A notification read from its banner: text, no record, no priority.
    func banner(_ token: String, title: String, body: String = "Hello", app: String = "com.example.chat") {
        manager.add(["token": token, "appName": "Chat", "bundleID": app, "title": title, "body": body])
    }

    /// A notification read from Notification Center's database.
    func record(
        _ uuid: String,
        title: String,
        body: String = "Hello",
        priority: NotificationPriority = .normal,
        app: String = "com.example.chat"
    ) {
        manager.add([
            "token": "db-\(uuid)", "appName": "Chat", "bundleID": app,
            "title": title, "body": body, "recordUUID": uuid, "priority": priority.rawValue,
        ])
    }

    /// The early signal that a notification reached the system.
    func earlySignal(_ uuid: String, app: String = "com.example.chat") async {
        manager.handleEarlySignal(["bundleID": app, "recordUUID": uuid])
        await settle()
    }

    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

@MainActor
final class SystemNotificationManagerTests: XCTestCase {
    private var harnesses: [NotificationHarness] = []

    private func makeHarness() -> NotificationHarness {
        let harness = NotificationHarness()
        harnesses.append(harness)
        return harness
    }

    override func tearDown() async throws {
        harnesses.forEach { $0.sleeper.finish() }
        harnesses.removeAll()
        await settle()
        try await super.tearDown()
    }

    // MARK: - Queue

    func testShowsANotificationForItsDisplayTime() async {
        let h = makeHarness()
        h.banner("b1", title: "One")
        await settle()
        XCTAssertEqual(h.active?.id, "b1")
        XCTAssertEqual(h.sleeper.requested, [4])

        await h.sleeper.elapse(4)
        XCTAssertNil(h.active)
        XCTAssertFalse(h.manager.lastDismissByUser)
    }

    func testANewNotificationReplacesTheActiveOneWhileNobodyIsLooking() async {
        let h = makeHarness()
        h.banner("b1", title: "One")
        h.banner("b2", title: "Two")
        XCTAssertEqual(h.active?.id, "b2")
        XCTAssertEqual(h.queuedIDs, [])
    }

    func testQueuesWhileThePointerIsOverTheNotch() async {
        let h = makeHarness()
        h.banner("b1", title: "One")
        h.manager.holdActive()
        h.banner("b2", title: "Two")
        h.banner("b3", title: "Three")
        XCTAssertEqual(h.active?.id, "b1")
        XCTAssertEqual(h.queuedIDs, ["b2", "b3"])

        h.manager.dismissActive()
        XCTAssertTrue(h.manager.lastDismissByUser)
        XCTAssertEqual(h.active?.id, "b2")
        XCTAssertEqual(h.queuedIDs, ["b3"])
    }

    func testQueueKeepsTheFiveNewest() async {
        let h = makeHarness()
        h.banner("b0", title: "Zero")
        h.manager.holdActive()
        for index in 1...7 {
            h.banner("b\(index)", title: "Title \(index)")
        }
        XCTAssertEqual(h.queuedIDs, ["b3", "b4", "b5", "b6", "b7"])
    }

    func testShowNextQueuedPutsTheActiveOneBackInLine() async {
        let h = makeHarness()
        h.banner("b1", title: "One")
        h.manager.holdActive()
        h.banner("b2", title: "Two")
        h.banner("b3", title: "Three")

        h.manager.showNextQueued()
        XCTAssertEqual(h.active?.id, "b2")
        XCTAssertEqual(h.queuedIDs, ["b3", "b1"])
    }

    func testLeavingTheNotchDropsTheQueueAndLetsTheActiveOneExpire() async {
        let h = makeHarness()
        h.banner("b1", title: "One")
        h.manager.holdActive()
        h.banner("b2", title: "Two")

        h.manager.resumeDismiss()
        await settle()
        XCTAssertEqual(h.queuedIDs, [])
        XCTAssertEqual(h.sleeper.requested.last, 2)

        await h.sleeper.elapse(2)
        XCTAssertNil(h.active)
    }

    func testHoldingStopsTheExpiry() async {
        let h = makeHarness()
        h.banner("b1", title: "One")
        await settle()
        h.manager.holdActive()
        await h.sleeper.elapse(4)
        XCTAssertEqual(h.active?.id, "b1")
    }

    // MARK: - Duplicates

    func testBannerAndDatabaseCopiesOfOneNotificationShowOnce() async {
        let h = makeHarness()
        h.banner("b1", title: "Lunch?")
        h.advance(5)
        h.record("AAAA0001", title: "Lunch?")
        XCTAssertEqual(h.active?.id, "b1")
        XCTAssertEqual(h.history.count, 1)
    }

    func testTwoRecordsWithTheSameTextAreTwoNotifications() async {
        // An app that hides its previews sends the same words every time.
        let h = makeHarness()
        h.record("AAAA0001", title: "New message")
        h.record("AAAA0002", title: "New message")
        XCTAssertEqual(h.active?.id, "db-AAAA0002")
        XCTAssertEqual(h.history.count, 2)
    }

    func testTheSameRecordTwiceShowsOnce() async {
        let h = makeHarness()
        h.record("AAAA0001", title: "New message")
        h.manager.dismissActive()
        h.record("AAAA0001", title: "New message")
        XCTAssertNil(h.active)
        XCTAssertEqual(h.history.count, 1)
    }

    func testTheSameTextAfterTheWindowIsANewNotification() async {
        let h = makeHarness()
        h.banner("b1", title: "Ping")
        h.advance(SystemNotificationManager.duplicateWindow + 1)
        h.banner("b2", title: "Ping")
        XCTAssertEqual(h.active?.id, "b2")
        XCTAssertEqual(h.history.count, 2)
    }

    // MARK: - Early placeholder

    func testPlaceholderShowsTheAppThenTheTextFillsItIn() async {
        let h = makeHarness()
        await h.earlySignal("CAFE0001")
        XCTAssertNil(h.active, "waits for the real notification first")
        XCTAssertEqual(h.sleeper.requested, [SystemNotificationManager.placeholderDelay])

        await h.sleeper.elapse(SystemNotificationManager.placeholderDelay)
        XCTAssertEqual(h.active?.id, "early-CAFE0001")
        XCTAssertEqual(h.active?.isPlaceholder, true)
        // Outlives the database's delay, whatever the display time is.
        XCTAssertEqual(h.sleeper.requested.last, SystemNotificationManager.placeholderMinimumDuration)

        h.advance(5)
        h.record("CAFE0001", title: "Dinner at 8")
        await settle()
        XCTAssertEqual(h.active?.id, "early-CAFE0001", "upgraded in place, not replaced")
        XCTAssertEqual(h.active?.title, "Dinner at 8")
        XCTAssertEqual(h.active?.isPlaceholder, false)
        XCTAssertEqual(h.sleeper.requested.last, 4, "the text gets its full time from now")
        XCTAssertEqual(h.history.map(\.notification.title), ["Dinner at 8"])

        // A late banner copy of the same text is not shown again.
        h.banner("b1", title: "Dinner at 8")
        XCTAssertEqual(h.active?.id, "early-CAFE0001")
    }

    func testNoPlaceholderWhenTheRealNotificationCameFirst() async {
        let h = makeHarness()
        await h.earlySignal("CAFE0001")
        h.banner("b1", title: "Already here")
        await h.sleeper.elapse(SystemNotificationManager.placeholderDelay)
        XCTAssertEqual(h.active?.id, "b1")
    }

    func testTextOfAPlaceholderTheUserClosedDoesNotComeBack() async {
        let h = makeHarness()
        await h.earlySignal("CAFE0001")
        await h.sleeper.elapse(SystemNotificationManager.placeholderDelay)
        h.manager.dismissActive()

        h.record("CAFE0001", title: "Dinner at 8")
        XCTAssertNil(h.active)
        XCTAssertEqual(h.history.count, 1, "still kept in the history")
    }

    func testNoPlaceholderWhenTurnedOff() async {
        let h = makeHarness()
        h.settings.earlyPlaceholder = false
        await h.earlySignal("CAFE0001")
        XCTAssertEqual(h.sleeper.requested, [])
        XCTAssertNil(h.active)
    }

    func testPlaceholderQueuesWhileThePointerIsOverTheNotch() async {
        let h = makeHarness()
        h.banner("b1", title: "One")
        h.manager.holdActive()
        // Long enough after b1 that it doesn't count as this app's real
        // notification having arrived already.
        h.advance(5)
        await h.earlySignal("CAFE0001")
        await h.sleeper.elapse(SystemNotificationManager.placeholderDelay)
        XCTAssertEqual(h.queuedIDs, ["early-CAFE0001"])

        h.record("CAFE0001", title: "Dinner at 8")
        XCTAssertEqual(h.queuedIDs, ["early-CAFE0001"])
        XCTAssertEqual(h.manager.queuedNotifications.first?.title, "Dinner at 8")
    }

    // MARK: - Time-sensitive notifications

    func testTimeSensitiveStaysTwiceAsLong() async {
        let h = makeHarness()
        h.record("BEEF0001", title: "Leave now", priority: .high)
        await settle()
        XCTAssertEqual(h.active?.priority, .high)
        XCTAssertEqual(h.sleeper.requested, [4 * SystemNotificationManager.highPriorityDurationFactor])
    }

    func testOrdinaryNotificationsWaitBehindATimeSensitiveOne() async {
        let h = makeHarness()
        h.record("BEEF0001", title: "Leave now", priority: .high)
        h.banner("b1", title: "Ordinary one")
        h.banner("b2", title: "Ordinary two")
        XCTAssertEqual(h.active?.id, "db-BEEF0001")

        await h.sleeper.elapse(8)
        XCTAssertEqual(h.active?.id, "b1")
        h.manager.dismissActive()
        XCTAssertEqual(h.active?.id, "b2")
    }

    func testOnlyTheLastThreeWaitBehindATimeSensitiveOne() async {
        let h = makeHarness()
        h.record("BEEF0001", title: "Leave now", priority: .high)
        for index in 1...5 {
            h.banner("b\(index)", title: "Ordinary \(index)")
        }
        await h.sleeper.elapse(8)
        XCTAssertEqual(h.active?.id, "b3")
    }

    func testAnotherTimeSensitiveOneTakesOver() async {
        let h = makeHarness()
        h.record("BEEF0001", title: "Leave now", priority: .high)
        h.record("BEEF0002", title: "Gate change", priority: .high)
        XCTAssertEqual(h.active?.id, "db-BEEF0002")
    }

    func testWithoutTheHighlightPriorityChangesNothing() async {
        let h = makeHarness()
        h.settings.priorityHighlight = false
        h.record("BEEF0001", title: "Leave now", priority: .high)
        await settle()
        XCTAssertEqual(h.sleeper.requested, [4])
        h.banner("b1", title: "Ordinary")
        XCTAssertEqual(h.active?.id, "b1")
    }

    func testDatabaseCopyRaisesTheBannerOnScreenToTimeSensitive() async {
        let h = makeHarness()
        h.banner("b1", title: "Leave now")
        await settle()
        XCTAssertEqual(h.active?.priority, .normal)

        h.record("BEEF0001", title: "Leave now", priority: .high)
        await settle()
        XCTAssertEqual(h.active?.id, "b1")
        XCTAssertEqual(h.active?.priority, .high)
        XCTAssertEqual(h.sleeper.requested.last, 8)
    }

    // MARK: - Focus

    func testFollowingFocusShowsBannersTheSystemLetThrough() async {
        let h = makeHarness()
        h.isFocused = true
        h.banner("b1", title: "Allowed by Focus")
        XCTAssertEqual(h.active?.id, "b1")
    }

    func testFollowingFocusKeepsOrdinaryRecordsOutOfTheNotch() async {
        let h = makeHarness()
        h.isFocused = true
        h.record("AAAA0001", title: "Silenced")
        XCTAssertNil(h.active)
        XCTAssertEqual(h.history.count, 1)
        XCTAssertEqual(h.history.first?.silenced, true)
    }

    func testFollowingFocusLetsTimeSensitiveRecordsThrough() async {
        let h = makeHarness()
        h.isFocused = true
        h.record("BEEF0001", title: "Leave now", priority: .high)
        XCTAssertEqual(h.active?.id, "db-BEEF0001")
    }

    func testFollowingFocusHoldsBackPlaceholders() async {
        let h = makeHarness()
        h.isFocused = true
        await h.earlySignal("CAFE0001")
        await h.sleeper.elapse(SystemNotificationManager.placeholderDelay)
        XCTAssertNil(h.active)
    }

    func testHideAllDuringFocusHidesEverything() async {
        let h = makeHarness()
        h.isFocused = true
        h.settings.focusBehavior = .hideAll
        h.banner("b1", title: "Banner")
        h.record("BEEF0001", title: "Leave now", priority: .high)
        XCTAssertNil(h.active)
        XCTAssertEqual(h.history.map(\.silenced), [true, true])
    }

    func testShowAllDuringFocusShowsEverything() async {
        let h = makeHarness()
        h.isFocused = true
        h.settings.focusBehavior = .showAll
        h.record("AAAA0001", title: "Ordinary record")
        XCTAssertEqual(h.active?.id, "db-AAAA0001")
    }

    func testFocusOffShowsEverything() async {
        let h = makeHarness()
        h.settings.focusBehavior = .hideAll
        h.record("AAAA0001", title: "Ordinary record")
        XCTAssertEqual(h.active?.id, "db-AAAA0001")
    }

    func testTestNotificationsIgnoreFocus() async {
        let h = makeHarness()
        h.isFocused = true
        h.settings.focusBehavior = .hideAll
        h.manager.add(["token": "test-1", "appName": "NekoNotch", "title": "Test notification"])
        XCTAssertEqual(h.active?.id, "test-1")
    }

    // MARK: - Which apps

    func testExcludedAppsAreLeftToTheSystem() async {
        let h = makeHarness()
        h.settings.excludedApps = ["com.example.chat"]
        h.banner("b1", title: "Excluded")
        XCTAssertNil(h.active)
        XCTAssertTrue(h.history.isEmpty)
    }

    func testOnlyAllowedAppsWhenNotAllAppsAreMirrored() async {
        let h = makeHarness()
        h.settings.fromAllApps = false
        h.settings.allowedApps = ["com.example.mail"]
        h.banner("b1", title: "From chat")
        XCTAssertNil(h.active)
        h.banner("b2", title: "From mail", app: "com.example.mail")
        XCTAssertEqual(h.active?.id, "b2")
    }

    func testIconOnlyAppsShowOnlyTheirIcon() async {
        let h = makeHarness()
        h.settings.iconOnlyApps = ["com.example.chat"]
        h.banner("b1", title: "Icon only")
        await settle()
        XCTAssertNil(h.active)
        XCTAssertEqual(h.manager.iconPeek?.id, "b1")

        await h.sleeper.elapse(4)
        XCTAssertNil(h.manager.iconPeek)
    }

    func testFullScreenRunsTheTextUnderTheNotch() async {
        let h = makeHarness()
        h.hidesNotch = true
        h.banner("b1", title: "While full screen")
        XCTAssertNil(h.active)
        XCTAssertEqual(h.manager.ticker?.id, "b1")
        XCTAssertEqual(h.manager.iconPeek?.id, "b1")

        h.manager.finishTicker("b1")
        XCTAssertNil(h.manager.ticker)
        XCTAssertNil(h.manager.iconPeek)
    }
}
