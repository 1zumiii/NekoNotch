//
//  ClosedNotchLayoutTests.swift
//  boringNotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import XCTest
@testable import boringNotch

final class ClosedNotchLayoutTests: XCTestCase {
    /// A 1512 × 982 screen with a 200 pt cutout: the cutout runs from 656 to
    /// 856, the left wing's outer edge is at 656 - 8 - 70 - 6 = 572, and the
    /// closed row reaches down to 982 - 32 - 8 = 942.
    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let layout = ClosedNotchLayout(
        cutoutWidth: 200,
        rowHeight: 32,
        effectiveRowHeight: 32,
        catWingWidth: 70,
        edgeMargin: 8,
        bottomCornerRadius: 6
    )

    private var layout: ClosedNotchLayout { Self.layout }
    private var screen: CGRect { Self.screen }

    // MARK: Chin width

    func testChinWidthOfPlainCutout() {
        XCTAssertEqual(layout.chinWidth(for: .cutout), 200)
    }

    func testChinWidthOfFixedWidthContent() {
        XCTAssertEqual(layout.chinWidth(for: .fallbackNotice(width: 420)), 420)
        XCTAssertEqual(layout.chinWidth(for: .batteryStatus), 640)
    }

    func testChinWidthOfNotification() {
        // Icon side 32 - 12 = 20 on each side, plus 20.
        XCTAssertEqual(layout.chinWidth(for: .notification(withCat: false)), 200 + 40 + 20)
        // Beside the cat it is the cat's row, as wide as the idle cat's.
        XCTAssertEqual(layout.chinWidth(for: .notification(withCat: true)), 200 + 140 + 16)
    }

    func testNotificationUsesConfiguredHeightAndMusicUsesDrawnHeight() {
        var zeroHeight = layout
        zeroHeight.rowHeight = 10
        zeroHeight.effectiveRowHeight = 0
        XCTAssertEqual(zeroHeight.chinWidth(for: .notification(withCat: false)), 200 + 0 + 20)
        XCTAssertEqual(zeroHeight.chinWidth(for: .music(withCat: false, inlinePeekWidth: nil)),
                       200 + 0 + 20 + 16 + 2)
    }

    func testChinWidthOfMusic() {
        let plain: CGFloat = 200 + 40 + 20 + 16 + 2
        XCTAssertEqual(layout.chinWidth(for: .music(withCat: false, inlinePeekWidth: nil)), plain)
        // Beside the cat it is the cat's row, widened by the peek's labels.
        XCTAssertEqual(layout.chinWidth(for: .music(withCat: true, inlinePeekWidth: nil)), 200 + 140 + 16)
        XCTAssertEqual(layout.chinWidth(for: .music(withCat: true, inlinePeekWidth: 110)), 200 + 140 + 16 + 220)
    }

    func testChinWidthOfIdleCat() {
        XCTAssertEqual(layout.chinWidth(for: .idleCat), 200 + 140 + 16)
    }

    // MARK: Wings on screen

    func testLeftWingSpan() {
        XCTAssertEqual(layout.leftWingSpan(on: screen), .init(outer: 572, cutout: 656))
    }

    func testPointerBesideCutout() {
        XCTAssertTrue(layout.pointerIsBesideCutout(CGPoint(x: 600, y: 960), on: screen, slack: 2))
        XCTAssertTrue(layout.pointerIsBesideCutout(CGPoint(x: 570, y: 960), on: screen, slack: 2))
        XCTAssertFalse(layout.pointerIsBesideCutout(CGPoint(x: 569, y: 960), on: screen, slack: 2))
        XCTAssertTrue(layout.pointerIsBesideCutout(CGPoint(x: 512, y: 960), on: screen, slack: 60))
        // Over the cutout itself, or below the closed row.
        XCTAssertFalse(layout.pointerIsBesideCutout(CGPoint(x: 700, y: 960), on: screen, slack: 60))
        XCTAssertFalse(layout.pointerIsBesideCutout(CGPoint(x: 600, y: 940), on: screen, slack: 60))
    }

    func testPointerOverCatWing() {
        // Right of the cutout (856), up to 856 + 16 + 70 + 12 = 954.
        XCTAssertTrue(layout.pointerIsOverCatWing(CGPoint(x: 900, y: 970), on: screen))
        XCTAssertFalse(layout.pointerIsOverCatWing(CGPoint(x: 856, y: 970), on: screen))
        XCTAssertFalse(layout.pointerIsOverCatWing(CGPoint(x: 954, y: 970), on: screen))
        XCTAssertFalse(layout.pointerIsOverCatWing(CGPoint(x: 900, y: 900), on: screen))
    }

    func testOnlyMenusEndingUnderTheWingAreCovered() {
        XCTAssertTrue(layout.leftWingCoversMenus(endingAt: [300, 610], on: screen))
        // Ending at or just left of the wing's edge: still clickable.
        XCTAssertFalse(layout.leftWingCoversMenus(endingAt: [300, 574], on: screen))
        // Put past the cutout by the system.
        XCTAssertFalse(layout.leftWingCoversMenus(endingAt: [658, 900], on: screen))
        XCTAssertTrue(layout.leftWingCoversMenus(endingAt: [657], on: screen))
        XCTAssertFalse(layout.leftWingCoversMenus(endingAt: [], on: screen))
    }
}
