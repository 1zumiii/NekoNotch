//
//  LeftWingMenuAvoidanceTests.swift
//  boringNotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import XCTest
@testable import boringNotch

/// Uses the screen and layout of `ClosedNotchLayoutTests`: the left wing runs
/// from 572 to the cutout at 656, with the closed row above y = 942.
final class LeftWingMenuAvoidanceTests: XCTestCase {
    private let layout = ClosedNotchLayoutTests.layout
    private let screen = ClosedNotchLayoutTests.screen
    private let start = ContinuousClock.now

    /// Over the wing.
    private let onWing = CGPoint(x: 600, y: 960)
    /// Left of the wing, inside the 60 pt that keeps it folded but outside
    /// the 2 pt that starts a check.
    private let nearWing = CGPoint(x: 530, y: 960)
    /// Well away, over other menus.
    private let away = CGPoint(x: 300, y: 960)

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(milliseconds))
    }

    private func poll(
        _ avoidance: inout LeftWingMenuAvoidance,
        at milliseconds: Int,
        pointer: CGPoint,
        menuIsOpen: Bool = false
    ) -> Bool {
        avoidance.poll(at: at(milliseconds), pointer: pointer, layout: layout, screen: screen, menuIsOpen: menuIsOpen)
    }

    private func folded() -> LeftWingMenuAvoidance {
        var avoidance = LeftWingMenuAvoidance()
        avoidance.fold()
        return avoidance
    }

    func testComingOverTheWingStartsACheckAndFolds() {
        var avoidance = LeftWingMenuAvoidance()
        XCTAssertTrue(avoidance.shouldCheckMenus(pointer: onWing, layout: layout, screen: screen))
        XCTAssertFalse(avoidance.shouldCheckMenus(pointer: nearWing, layout: layout, screen: screen))
        XCTAssertFalse(avoidance.shouldCheckMenus(pointer: away, layout: layout, screen: screen))

        XCTAssertTrue(avoidance.confirmsFold(pointer: onWing, layout: layout, screen: screen))
        avoidance.fold()
        XCTAssertTrue(avoidance.isFolded)
    }

    func testNoFoldWhenThePointerLeftDuringTheCheck() {
        let avoidance = LeftWingMenuAvoidance()
        XCTAssertFalse(avoidance.confirmsFold(pointer: away, layout: layout, screen: screen))
    }

    func testFoldedWingIsLatchedAndNotCheckedAgain() {
        let avoidance = folded()
        XCTAssertFalse(avoidance.shouldCheckMenus(pointer: onWing, layout: layout, screen: screen))
        XCTAssertFalse(avoidance.confirmsFold(pointer: onWing, layout: layout, screen: screen))
    }

    func testStaysFoldedWhileThePointerStaysInRange() {
        var avoidance = folded()
        for milliseconds in stride(from: 250, through: 5000, by: 250) {
            let pointer = milliseconds.isMultiple(of: 500) ? onWing : nearWing
            XCTAssertFalse(poll(&avoidance, at: milliseconds, pointer: pointer))
        }
        XCTAssertTrue(avoidance.isFolded)
    }

    func testComesBackHalfASecondAfterThePointerLeaves() {
        var avoidance = folded()
        XCTAssertFalse(poll(&avoidance, at: 250, pointer: away))
        XCTAssertFalse(poll(&avoidance, at: 500, pointer: away))
        XCTAssertFalse(poll(&avoidance, at: 749, pointer: away))
        XCTAssertTrue(avoidance.isFolded)
        XCTAssertTrue(poll(&avoidance, at: 750, pointer: away))
        XCTAssertFalse(avoidance.isFolded)
    }

    func testReturningWithinHalfASecondStartsTheWaitOver() {
        var avoidance = folded()
        XCTAssertFalse(poll(&avoidance, at: 250, pointer: away))
        XCTAssertFalse(poll(&avoidance, at: 500, pointer: away))
        XCTAssertFalse(poll(&avoidance, at: 700, pointer: nearWing))
        XCTAssertFalse(poll(&avoidance, at: 750, pointer: away))
        XCTAssertFalse(poll(&avoidance, at: 1000, pointer: away))
        XCTAssertTrue(poll(&avoidance, at: 1250, pointer: away))
    }

    func testStaysFoldedWhileAMenuIsOpen() {
        var avoidance = folded()
        for milliseconds in stride(from: 250, through: 3000, by: 250) {
            XCTAssertFalse(poll(&avoidance, at: milliseconds, pointer: away, menuIsOpen: true))
        }
        // The menu closes: the half second starts only now.
        XCTAssertFalse(poll(&avoidance, at: 3250, pointer: away))
        XCTAssertFalse(poll(&avoidance, at: 3500, pointer: away))
        XCTAssertTrue(poll(&avoidance, at: 3750, pointer: away))
    }

    func testNoFlickerAtTheEdge() {
        // Hovering just left of the wing: too far to start a check, close
        // enough to keep a folded wing folded.
        var avoidance = folded()
        for milliseconds in stride(from: 250, through: 3000, by: 250) {
            XCTAssertFalse(poll(&avoidance, at: milliseconds, pointer: nearWing))
        }
        XCTAssertTrue(avoidance.isFolded)

        var unfolded = LeftWingMenuAvoidance()
        XCTAssertFalse(unfolded.shouldCheckMenus(pointer: nearWing, layout: layout, screen: screen))
        XCTAssertFalse(poll(&unfolded, at: 250, pointer: nearWing))
        XCTAssertFalse(unfolded.isFolded)
    }

    func testAfterComingBackThePointerHasToComeOverItAgain() {
        var avoidance = folded()
        _ = poll(&avoidance, at: 250, pointer: away)
        XCTAssertTrue(poll(&avoidance, at: 750, pointer: away))

        // Polling no longer does anything, wherever the pointer is.
        XCTAssertFalse(poll(&avoidance, at: 1000, pointer: onWing))
        XCTAssertFalse(avoidance.isFolded)
        // Lingering near the wing does not fold it; coming over it starts a
        // new check.
        XCTAssertFalse(avoidance.shouldCheckMenus(pointer: nearWing, layout: layout, screen: screen))
        XCTAssertTrue(avoidance.shouldCheckMenus(pointer: onWing, layout: layout, screen: screen))
    }

    func testUnfoldBringsTheWingBackAtOnce() {
        var avoidance = folded()
        _ = poll(&avoidance, at: 250, pointer: away)
        avoidance.unfold()
        XCTAssertFalse(avoidance.isFolded)
        // A later fold starts with no leftover wait.
        avoidance.fold()
        XCTAssertFalse(poll(&avoidance, at: 600, pointer: away))
        XCTAssertFalse(poll(&avoidance, at: 1000, pointer: away))
        XCTAssertTrue(poll(&avoidance, at: 1100, pointer: away))
    }
}
