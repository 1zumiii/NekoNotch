//
//  ShootingStars.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Now and then a shooting star crosses the sky behind the cat: a short
//  streak of light falling down and to the left, there and gone in under a
//  second. One layer, reused; Core Animation moves and fades it, and a timer
//  picks when the next one comes.
//
import AppKit
import QuartzCore

/// Used on the main thread only, like the sky it sits in; the timer fires on
/// the main run loop.
final class ShootingStars: @unchecked Sendable {
    /// Fills the sky; the shooting star crosses it.
    let layer = CALayer()
    private let meteor = CALayer()
    private var image: CGImage?
    private var scale: CGFloat = 2
    private var timer: Timer?
    private var running = false
    private var suspended = false

    /// Seconds between one shooting star and the next.
    private static let gaps: ClosedRange<Double> = 15...45
    /// Head to tail, in points.
    private static let length: CGFloat = 16
    private static let flightKey = "flight"

    init() {
        meteor.opacity = 0
        layer.addSublayer(meteor)
    }

    func setScale(_ scale: CGFloat) {
        self.scale = scale
        image = Self.streak(scale: scale)
        meteor.contents = image
        meteor.contentsScale = scale
    }

    /// The first comes a little while after the sky appears, not at once.
    func start() {
        guard !running else { return }
        running = true
        schedule(after: .random(in: 5...25))
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        meteor.removeAnimation(forKey: Self.flightKey)
    }

    /// None while the sky is at warp; the one out finishes its flight.
    func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
    }

    private func schedule(after delay: Double) {
        timer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.fire() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fire() {
        timer = nil
        guard running else { return }
        if !suspended { launch() }
        schedule(after: .random(in: Self.gaps))
    }

    /// From somewhere in the upper right of the sky, down and to the left
    /// at a shallow angle, bright in the middle of its flight.
    private func launch() {
        let bounds = layer.bounds
        guard let image, bounds.width > 40, bounds.height > 8 else { return }
        let angle = CGFloat.random(in: 0.3...0.6)
        let distance = CGFloat.random(in: 28...44)
        let start = CGPoint(
            x: .random(in: bounds.width * 0.35...bounds.width - 4),
            y: .random(in: bounds.height * 0.55...bounds.height - 2)
        )
        let end = CGPoint(x: start.x - distance * cos(angle), y: start.y - distance * sin(angle))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        meteor.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        // The image's head is in its middle with the tail to the right, so
        // turning it by the angle lays the tail back along the path.
        meteor.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        meteor.position = end
        meteor.opacity = 0
        CATransaction.commit()

        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: start)
        move.toValue = NSValue(point: end)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0.9, 0]
        fade.keyTimes = [0, 0.2, 0.55, 1]
        let flight = CAAnimationGroup()
        flight.animations = [move, fade]
        flight.duration = .random(in: 1.1...1.5)
        flight.timingFunction = CAMediaTimingFunction(name: .easeIn)
        flight.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 30)
        meteor.add(flight, forKey: Self.flightKey)
    }

    /// A thin white streak, twice its length wide with the head in the
    /// middle, fading out along the tail.
    private static func streak(scale: CGFloat) -> CGImage? {
        let length = Int((Self.length * scale).rounded())
        let thickness = max(1, Int(scale.rounded()))
        guard let context = CGContext(
            data: nil, width: 2 * length, height: thickness, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        for x in 0..<length {
            let fade = 1 - CGFloat(x) / CGFloat(length)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: fade * fade)
            context.fill(CGRect(x: length + x, y: 0, width: 1, height: thickness))
        }
        return context.makeImage()
    }
}
