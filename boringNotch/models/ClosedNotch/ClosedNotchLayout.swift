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
            let iconSide = max(0, effectiveRowHeight - 12)
            var width = cutoutWidth + 2 * iconSide + 20
            if withCat { width += 2 * (catWingWidth - iconSide) }
            return width
        case .music(let withCat, let inlinePeekWidth):
            let artSide = max(0, rowHeight - 12)
            var width = cutoutWidth + 2 * artSide + 20 + 2 * edgeMargin + 2
            if withCat { width += 2 * (catWingWidth - artSide) }
            if let inlinePeekWidth { width += 2 * inlinePeekWidth }
            return width
        case .idleCat:
            return cutoutWidth + 2 * catWingWidth + 2 * edgeMargin
        }
    }

    // MARK: - Wings on screen

    struct WingSpan: Equatable {
        /// Left end of the empty wing, in screen points.
        var outer: CGFloat
        /// Left edge of the cutout.
        var cutout: CGFloat
    }

    /// From the left wing's outer edge to the cutout.
    func leftWingSpan(on screen: CGRect) -> WingSpan {
        let cutout = screen.midX - cutoutWidth / 2
        return WingSpan(outer: cutout - edgeMargin - catWingWidth - bottomCornerRadius, cutout: cutout)
    }

    /// Whether the pointer is in the menu bar, from `slack` points left of
    /// the wing to the cutout.
    func pointerIsBesideCutout(_ pointer: CGPoint, on screen: CGRect, slack: CGFloat) -> Bool {
        let span = leftWingSpan(on: screen)
        return pointer.x >= span.outer - slack && pointer.x <= span.cutout
            && isAtRowHeight(pointer, on: screen)
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
        let span = leftWingSpan(on: screen)
        return menuEdges.contains { $0 > span.outer + 2 && $0 <= span.cutout + 1 }
    }

    private func isAtRowHeight(_ pointer: CGPoint, on screen: CGRect) -> Bool {
        pointer.y > screen.maxY - rowHeight - 8
    }
}
