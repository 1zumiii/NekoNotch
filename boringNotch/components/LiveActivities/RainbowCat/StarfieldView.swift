//
//  StarfieldView.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The empty wing opposite the cat: the same sky, and the warp ring
//  rushing out across it.
//
import AppKit
import SwiftUI

/// The empty wing opposite the cat: the same sky drifting by, so the closed
/// notch looks alike on both sides.
final class StarfieldNSView: NSView {
    private let stage = CALayer()
    private let sky = StarSky()
    /// The warp ring the cat flew through, rushing out across this wing.
    private let ring = CALayer()
    private static let ringKey = "ring"
    private var renderedScale: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(stage)
        stage.masksToBounds = true
        stage.addSublayer(sky.layer)
        ring.magnificationFilter = .nearest
        ring.opacity = 0
        stage.addSublayer(ring)
    }

    /// Both halves of the ring in one image: there is no cat here to go between them.
    private func renderRing(scale: CGFloat) {
        guard let halves = PixelCatSprites.warpRingImages(scale: scale) else { return }
        let width = halves.back.width, height = halves.back.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(halves.back, in: rect)
        context.draw(halves.front, in: rect)
        ring.contents = context.makeImage()
        ring.contentsScale = scale
        ring.bounds = CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
    }

    /// Comes out from behind the notch where the pass says the ring is by
    /// then, and leaves the outer edge, still speeding up.
    private func flyRing(_ pass: WarpRingFlight.Pass?) {
        guard let pass else {
            RainbowCatNSView.fadeOut(ring, forKey: Self.ringKey, speed: 1 / StarSky.effectiveSpeed(of: stage))
            return
        }
        guard let window, ObjectIdentifier(window) == pass.window, ring.contents != nil,
              let space = WarpRingFlight.Space(stage, in: window) else { return }
        let width = ring.bounds.width
        let enter = pass.time(atX: space.root(stage.bounds.maxX + width / 2))
        let leave = pass.time(atX: space.root(-width / 2))
        guard leave > enter, leave > CACurrentMediaTime() else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.position = CGPoint(x: stage.bounds.maxX + width, y: stage.bounds.midY)
        CATransaction.commit()
        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.values = pass.keyframes(from: enter, to: leave, in: space, steps: 12)
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 1
        show.toValue = 1
        let flight = CAAnimationGroup()
        flight.animations = [move, show]
        flight.duration = leave - enter
        flight.beginTime = ring.convertTime(enter, from: nil)
        flight.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        ring.add(flight, forKey: Self.ringKey)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Stars are born out of sight under the notch, a stretch to the right
    /// of this wing, and drift out from behind it: the same sky that went
    /// behind the notch on the cat's side.
    private static let hiddenBuffer: CGFloat = 24

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let reach = RainbowCatNSView.innerReach + Self.hiddenBuffer
        stage.frame = CGRect(x: 0, y: 0, width: bounds.width + reach, height: bounds.height)
        sky.layout(bounds: stage.bounds, birthX: stage.bounds.maxX - StarSky.birthBand / 2)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            CPULoadMonitor.shared.stopObserving(self)
            WarpRingFlight.shared.stopObserving(self)
            sky.stop()
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        if scale != renderedScale {
            renderedScale = scale
            sky.setScale(scale)
            renderRing(scale: scale)
        }
        WarpRingFlight.shared.observe(self) { [weak self] pass in self?.flyRing(pass) }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            sky.stop()
            return
        }
        sky.start()
        // The same sky as on the cat's side, at the pace the settings give it.
        CPULoadMonitor.shared.observe(self) { [weak self] load in self?.sky.update(load: load, parentSpeed: 1) }
    }
}

struct RainbowStars: NSViewRepresentable {
    func makeNSView(context: Context) -> StarfieldNSView { StarfieldNSView(frame: .zero) }
    func updateNSView(_ view: StarfieldNSView, context: Context) {}
}
