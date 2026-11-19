//
//  ClosedNotchLayout.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import CoreGraphics

/// The geometry of the closed notch, apart from SwiftUI: how wide the hover
/// region under it is, where the cat's wings lie on screen, and where the
/// pointer is relative to them. `ContentView` decides what the notch shows;
/// this type does the arithmetic.
struct ClosedNotchLayout: Equatable {
    /// Width of the cutout the notch is drawn around.
    var cutoutWidth: CGFloat
    /// Height of the closed row as drawn: 10 pt when the notch height is zero.
    var rowHeight: CGFloat
    /// Height of the closed notch as configured.
    var effectiveRowHeight: CGFloat
    var catWingWidth: CGFloat
    /// Margin between the cutout and an activity beside it.
    var edgeMargin: CGFloat
    /// Radius of the closed notch's bottom corners.
    var bottomCornerRadius: CGFloat
    /// How far what the closed notch shows reaches left of the cutout (and,
    /// the row being symmetric, right of it), not counting the bottom
    /// corner. Nil for the cat's row.
    var leftReach: CGFloat? = nil

    // MARK: - Hover region

    /// What the closed notch shows, as far as its width is concerned.
    enum ChinContent: Equatable {
        /// Just the cutout.
        case cutout
        case fallbackNotice(width: CGFloat)
        case batteryStatus
        /// A notification's icon and dot, or its icon and the cat.
        case notification(withCat: Bool)
        /// The album art and the waveform or the cat, widened by the
        /// song-change peek when it shows.
        case music(withCat: Bool, inlinePeekWidth: CGFloat?)
        case idleCat
    }

    static let batteryStatusWidth: CGFloat = 640

    /// The cat's row: a wing either side of the cutout and its margins. The
    /// idle cat, and music or a notification beside the cat, all fill it.
    var catRowWidth: CGFloat {
        cutoutWidth + 2 * catWingWidth + 2 * edgeMargin
    }

    /// Width of the transparent chin under the closed notch, which is what
    /// the pointer can hover over.
    func chinWidth(for content: ChinContent) -> CGFloat {
        switch content {
        case .cutout:
            return cutoutWidth
        case .fallbackNotice(let width):
            return width
        case .batteryStatus:
            return Self.batteryStatusWidth
        case .notification(let withCat):
            // Beside the cat it is the cat's row.
            if withCat { return catRowWidth }
            let iconSide = max(0, effectiveRowHeight - 12)
            return cutoutWidth + 2 * iconSide + 20
        case .music(let withCat, let inlinePeekWidth):
            let peek = inlinePeekWidth.map { 2 * $0 } ?? 0
            if withCat { return catRowWidth + peek }
            let artSide = max(0, rowHeight - 12)
            return cutoutWidth + 2 * artSide + 20 + 2 * edgeMargin + 2 + peek
        case .idleCat:
            return catRowWidth
        }
    }

    // MARK: - Wings on screen

    /// The wing left of the cutout (the starry sky, or album art or an
    /// icon) or right of it (the cat, or what replaces it).
    enum WingSide: Equatable {
        case left, right
    }

    struct WingSpan: Equatable {
        /// Outer end of the wing, in screen points: its left end for the
        /// left wing, its right end for the right one.
        var outer: CGFloat
        /// The cutout's edge on that side.
        var cutout: CGFloat
    }

    /// How far the wings reach beside the cutout, not counting the bottom
    /// corner. The closed row is symmetric, so both wings reach as far.
    private var wingReach: CGFloat {
        leftReach ?? (edgeMargin + catWingWidth)
    }

    /// From the left wing's outer edge to the cutout.
    func leftWingSpan(on screen: CGRect) -> WingSpan {
        wingSpan(.left, on: screen)
    }

    func wingSpan(_ side: WingSide, on screen: CGRect) -> WingSpan {
        switch side {
        case .left:
            let cutout = screen.midX - cutoutWidth / 2
            return WingSpan(outer: cutout - wingReach - bottomCornerRadius, cutout: cutout)
        case .right:
            let cutout = screen.midX + cutoutWidth / 2
            return WingSpan(outer: cutout + wingReach + bottomCornerRadius, cutout: cutout)
        }
    }

    /// Whether the pointer is in the menu bar over a wing, from the cutout
    /// to `slack` points past the wing's outer end.
    func pointerIsBesideCutout(
        _ pointer: CGPoint, on screen: CGRect, slack: CGFloat, side: WingSide = .left
    ) -> Bool {
        let span = wingSpan(side, on: screen)
        let beside: Bool
        switch side {
        case .left: beside = pointer.x >= span.outer - slack && pointer.x <= span.cutout
        case .right: beside = pointer.x >= span.cutout && pointer.x <= span.outer + slack
        }
        return beside && isAtRowHeight(pointer, on: screen)
    }

    /// Whether the pointer is right of the cutout, on the cat's wing.
    func pointerIsOverCatWing(_ pointer: CGPoint, on screen: CGRect) -> Bool {
        let cutoutEdge = screen.midX + cutoutWidth / 2
        return pointer.x > cutoutEdge
            && pointer.x < cutoutEdge + 2 * edgeMargin + catWingWidth + 12
            && isAtRowHeight(pointer, on: screen)
    }

    /// Whether a menu ending at one of `menuEdges` lies under the left wing.
    /// Menus the system has put past the cutout are not under it.
    func leftWingCoversMenus(endingAt menuEdges: [CGFloat], on screen: CGRect) -> Bool {
        wingCoversMenus(.left, endingAt: menuEdges, on: screen)
    }

    /// Whether a menu ending at one of `menuEdges` lies under the wing. An
    /// app with more menus than fit left of the cutout has the rest put
    /// right of it, starting at the cutout's edge, so any menu ending past
    /// that edge is at least partly under the right wing.
    func wingCoversMenus(_ side: WingSide, endingAt menuEdges: [CGFloat], on screen: CGRect) -> Bool {
        let span = wingSpan(side, on: screen)
        switch side {
        case .left: return menuEdges.contains { $0 > span.outer + 2 && $0 <= span.cutout + 1 }
        case .right: return menuEdges.contains { $0 > span.cutout + 2 }
        }
    }

    private func isAtRowHeight(_ pointer: CGPoint, on screen: CGRect) -> Bool {
        pointer.y > screen.maxY - rowHeight - 8
    }
}
