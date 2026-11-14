//
//  WarpRingFlight.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The ring the cat flies through on its way into warp goes on after it,
//  behind the notch and out across the empty wing on the other side. The
//  cat's view announces where and when the ring passes the cat, in the
//  window's root layer and media time, how fast it is going then and how hard it is
//  speeding up as the cat leaves it behind; the wing works out from that
//  when the ring comes out from behind the notch and leaves its edge.
//
import AppKit
import QuartzCore

@MainActor
final class WarpRingFlight {
    static let shared = WarpRingFlight()

    struct Pass {
        /// The window the cat is in: the notch's, or the settings' preview.
        let window: ObjectIdentifier
        /// Where the ring is over the cat, in the window's root layer: unlike
        /// view coordinates, these take in any scaling between (the
        /// settings' preview is drawn at twice the size).
        let x: CGFloat
        /// When it is there, in `CACurrentMediaTime`.
        let time: CFTimeInterval
        /// Root layer points a second, leftwards, as it passes the cat.
        let speed: CGFloat
        /// Root layer points a second squared: the cat going to warp leaves
        /// the ring behind faster and faster.
        let acceleration: CGFloat

        /// Where the ring's middle is at `time` (not before the pass).
        func x(at time: CFTimeInterval) -> CGFloat {
            let t = CGFloat(max(time - self.time, 0))
            return x - speed * t - acceleration / 2 * t * t
        }

        /// When the ring's middle is at `x`, left of the cat.
        func time(atX x: CGFloat) -> CFTimeInterval {
            let distance = max(self.x - x, 0)
            guard acceleration > 0 else { return time + CFTimeInterval(distance / speed) }
            let t = (-speed + (speed * speed + 2 * acceleration * distance).squareRoot()) / acceleration
            return time + CFTimeInterval(t)
        }

        /// The flight between two media times as evenly timed keyframes of
        /// an x in `space`.
        func keyframes(from start: CFTimeInterval, to end: CFTimeInterval, in space: Space, steps: Int = 24) -> [CGFloat] {
            (0...steps).map { step in
                space.local(x(at: start + (end - start) * Double(step) / Double(steps)))
            }
        }
    }

    /// A layer's x axis against the window's root layer, which the ring's
    /// flight is planned in.
    struct Space {
        let origin: CGFloat
        /// Root layer points per point of the layer.
        let scale: CGFloat

        init?(_ layer: CALayer, in window: NSWindow) {
            guard let root = window.contentView?.layer else { return nil }
            origin = layer.convert(CGPoint.zero, to: root).x
            let scale = layer.convert(CGPoint(x: 1, y: 0), to: root).x - origin
            guard scale > 0 else { return nil }
            self.scale = scale
        }

        func root(_ x: CGFloat) -> CGFloat { origin + x * scale }
        func local(_ x: CGFloat) -> CGFloat { (x - origin) / scale }
    }

    /// How hard the ring falls behind once the cat has passed it.
    static let acceleration: CGFloat = 450

    private var observers: [ObjectIdentifier: (Pass?) -> Void] = [:]

    /// `handler` gets each pass as it is announced, and nil when the cat
    /// turns back before the ring reaches it.
    func observe(_ owner: AnyObject, handler: @escaping (Pass?) -> Void) {
        observers[ObjectIdentifier(owner)] = handler
    }

    func stopObserving(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
    }

    func announce(_ pass: Pass?) {
        for handler in observers.values { handler(pass) }
    }
}
