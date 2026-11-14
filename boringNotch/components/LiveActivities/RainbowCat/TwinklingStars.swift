//
//  TwinklingStars.swift
//  boringNotch
//
//  A few stars among the emitted ones that twinkle as they drift by. Emitter
//  particles can only fade one way, so these are plain layers, each with a
//  drift and a looping brightness animation: Core Animation runs both, and
//  the only code is a relaunch when a star has left the sky.
//
import AppKit
import QuartzCore

final class TwinklingStars {
    /// Fills the sky's stage; the stars drift across it from right to left.
    let layer = CALayer()
    private var stars: [CALayer] = []
    private var farImages: [CGImage] = []
    private var nearImages: [CGImage] = []
    private var scale: CGFloat = 2
    private var running = false
    /// While suspended, stars that have crossed wait here instead of coming
    /// round again.
    private var suspended = false
    private var waiting: [CALayer] = []
    /// When the last star came in over the edge, in this layer's time.
    private var lastEntry: CFTimeInterval = -.infinity
    /// Stars come in at least this far apart, so two never drift by side by side.
    private static let minEntryGap: CFTimeInterval = 3
    private static let driftKey = "drift"
    private static let twinkleKey = "twinkle"

    init(count: Int) {
        stars = (0..<count).map { _ in
            let star = CALayer()
            star.magnificationFilter = .nearest
            star.opacity = 0
            layer.addSublayer(star)
            return star
        }
    }

    func setScale(_ scale: CGFloat) {
        self.scale = scale
        farImages = PixelCatSprites.starImages(scale: scale, near: false)
        nearImages = PixelCatSprites.starImages(scale: scale, near: true)
        if running {
            stop()
            start()
        }
    }

    /// Stars come in one by one at random times, so the sky fills slowly,
    /// the way the emitted stars do.
    func start() {
        guard !running else { return }
        running = true
        // One already on its way somewhere in the sky, as if it had been
        // going for a while; the rest come in later, kept apart.
        for (index, star) in stars.enumerated() {
            launch(star, delay: index < 1 ? 0 : .random(in: 0...10), midway: index < 1)
        }
    }

    /// The stars already out finish crossing; none come in until resumed.
    func setSuspended(_ suspended: Bool) {
        guard suspended != self.suspended else { return }
        self.suspended = suspended
        guard !suspended else { return }
        releaseWaiting()
    }

    /// Stars held back for want of a size go once the layer has one.
    func releaseWaiting() {
        guard running, !suspended, layer.bounds.width > 0 else { return }
        let resumed = waiting
        waiting = []
        for star in resumed { launch(star, delay: .random(in: 0...5)) }
    }

    func stop() {
        running = false
        suspended = false
        waiting = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for star in stars {
            star.removeAllAnimations()
            star.opacity = 0
        }
        CATransaction.commit()
    }

    fileprivate func launch(_ star: CALayer, delay: CFTimeInterval, midway: Bool = false) {
        guard running else { return }
        guard !suspended, layer.bounds.width > 0, !farImages.isEmpty, !nearImages.isEmpty else {
            waiting.append(star)
            return
        }
        // Near ones bigger and brighter, but all at the far stars' pace, so
        // one that comes in beside an emitted near star soon falls behind it.
        let near = Double.random(in: 0..<1) < 0.4
        guard let image = (near ? nearImages : farImages).randomElement() else { return }
        let velocity: CGFloat = 6
        let brightness: Float = near ? 1 : 0.7
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let y = (CGFloat.random(in: size.height / 2...max(size.height / 2, layer.bounds.height - size.height / 2)) * scale)
            .rounded() / scale
        let startX = midway
            ? .random(in: size.width...max(size.width, layer.bounds.maxX))
            : layer.bounds.maxX + size.width + .random(in: 0...16)
        let endX = -size.width

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        star.contents = image
        star.contentsScale = scale
        star.bounds = CGRect(origin: .zero, size: size)
        // Where it ends up: out of sight once the drift is over.
        star.position = CGPoint(x: endX, y: y)
        star.opacity = 0
        CATransaction.commit()

        var begin = star.convertTime(CACurrentMediaTime(), from: nil) + delay
        if !midway {
            begin = max(begin, lastEntry + Self.minEntryGap)
            lastEntry = begin
        }
        let drift = CABasicAnimation(keyPath: "position.x")
        drift.fromValue = startX
        drift.toValue = endX
        drift.duration = Double((startX - endX) / velocity)
        drift.beginTime = begin
        drift.fillMode = .backwards
        drift.delegate = DriftEnd(owner: self, star: star)

        // Bright most of the time, dimming now and then; each star at its
        // own pace and phase, so they never blink together.
        let twinkle = CAKeyframeAnimation(keyPath: "opacity")
        let dim = Float.random(in: 0.15...0.35)
        twinkle.values = [1, 1, dim, 1, 0.75, 1].map { $0 * brightness }
        twinkle.keyTimes = [0, 0.35, 0.5, 0.65, 0.82, 1]
        twinkle.duration = .random(in: 1.4...2.8)
        twinkle.timeOffset = .random(in: 0...twinkle.duration)
        twinkle.repeatDuration = drift.duration
        twinkle.beginTime = begin
        twinkle.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 15)

        star.add(twinkle, forKey: Self.twinkleKey)
        star.add(drift, forKey: Self.driftKey)
    }
}

/// Sends a star round again once it has crossed the sky. Removed or replaced
/// animations finish unfinished and are left alone.
private final class DriftEnd: NSObject, CAAnimationDelegate {
    private weak var owner: TwinklingStars?
    private weak var star: CALayer?

    init(owner: TwinklingStars, star: CALayer) {
        self.owner = owner
        self.star = star
    }

    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        guard finished, let owner, let star else { return }
        owner.launch(star, delay: .random(in: 0...6))
    }
}
