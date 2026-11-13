//
//  LeftWingMenuAvoidance.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import CoreGraphics

/// When the empty wing left of the cutout folds away to uncover the
/// frontmost app's last menus, and when it comes back.
///
/// The pointer coming over the wing starts a check (done by the caller,
/// through the XPC helper) of whether the wing covers menus; if it does, the
/// wing folds. Once folded it stays folded, without checking again, until
/// the pointer has been away from the wing for half a second with no menu
/// open. "Away" is measured from 60 pt left of the wing, wider than the
/// 2 pt that starts the check, so the wing doesn't flicker at its edge.
/// After it comes back, the pointer has to come over it again to fold it.
///
/// Time and the pointer are passed in, so the rules can be tested.
struct LeftWingMenuAvoidance: Equatable {
    /// Slack left of the wing within which coming over it starts a check.
    static let entrySlack: CGFloat = 2
    /// Slack left of the wing within which the pointer keeps it folded.
    static let stayingSlack: CGFloat = 60
    static let unfoldDelay: Duration = .milliseconds(500)
    /// How often the caller polls while the wing is folded.
    static let pollInterval: Duration = .milliseconds(250)

    private(set) var isFolded = false
    /// Since when the pointer has been away from the wing, with no menu open.
    private var awaySince: ContinuousClock.Instant?

    /// Whether the pointer coming over the notch should start a check of
    /// the menus under the wing.
    func shouldCheckMenus(pointer: CGPoint, layout: ClosedNotchLayout, screen: CGRect) -> Bool {
        !isFolded && layout.pointerIsBesideCutout(pointer, on: screen, slack: Self.entrySlack)
    }

    /// Whether the wing should fold once the check has found menus under
    /// it: the pointer must still be there.
    func confirmsFold(pointer: CGPoint, layout: ClosedNotchLayout, screen: CGRect) -> Bool {
        !isFolded && layout.pointerIsBesideCutout(pointer, on: screen, slack: Self.entrySlack)
    }

    mutating func fold() {
        isFolded = true
        awaySince = nil
    }

    /// One poll while folded. Returns true when the wing has just come back.
    mutating func poll(
        at now: ContinuousClock.Instant,
        pointer: CGPoint,
        layout: ClosedNotchLayout,
        screen: CGRect,
        menuIsOpen: Bool
    ) -> Bool {
        guard isFolded else { return false }
        if menuIsOpen || layout.pointerIsBesideCutout(pointer, on: screen, slack: Self.stayingSlack) {
            awaySince = nil
            return false
        }
        guard let since = awaySince else {
            awaySince = now
            return false
        }
        guard since.duration(to: now) >= Self.unfoldDelay else { return false }
        unfold()
        return true
    }

    /// Brings the wing back at once, as when the notch opens or shows
    /// something other than the idle cat.
    mutating func unfold() {
        isFolded = false
        awaySince = nil
    }
}
