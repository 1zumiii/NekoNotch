//
//  StarSky.swift
//  boringNotch
//
//  The sky behind the rainbow cat, and the empty wing opposite it: emitted
//  stars in three layers of depth, each star a little brighter or dimmer
//  than the next, a few that twinkle, now and then a shooting star, and,
//  once the CPU is busy enough, streaks of light as if the cat had gone to
//  warp speed.
//  Its layer keeps its own pace, set from the CPU load and the settings, so
//  the sky can speed up more than the cat does.
//
import AppKit
import Defaults
import QuartzCore

/// Used on the main thread only; its timer fires on the main run loop.
final class StarSky: @unchecked Sendable {
    /// Add to the stage; its frame is set by `layout`.
    let layer = CALayer()
    private let stars = CAEmitterLayer()
    /// Streaks have an emitter of their own, so going to warp can stop the
    /// stars being born and fling the ones already out away.
    private let streaks = CAEmitterLayer()
    /// Fills the whole sky at once when it starts, at the density it would
    /// have had by then, so a sky made anew (the notch closing again, say)
    /// isn't an empty one filling up from the outer edge.
    private let prefill = CAEmitterLayer()
    private var prefillHoldsStreaks = false
    /// Started before it was laid out: the sky is filled once it has a size.
    private var needsPrefill = false
    private static let prefillDuration: CFTimeInterval = 0.05
    private let twinkles = TwinklingStars(count: 3)
    private let meteors = ShootingStars()
    /// The stars put out as warp ends, braking with the cat (see `Brake`).
    /// While the brakes are on this layer keeps the pace the sky had at the
    /// cut, whatever the load does, so the beats land in real time.
    private let brakingStars = CALayer()
    /// Ends the brakes, `Brake.duration` after the cut.
    private var braking: Timer?
    /// How fast the sky's time ran at the cut.
    private var brakePace: Float = 1
    /// The sky at the cut holds about this many stars; a wide sky (the
    /// settings' preview) gets no more than this many braking ones.
    private static let maxBrakingStars = 40
    private var tailImages: [CGImage] = []
    private var images: [String: CGImage] = [:]
    private var birthX: CGFloat = 0
    private var scale: CGFloat = 2
    /// Warp as the stars and streaks show it.
    private var warping = false
    /// Warp as the CPU load asks for it; going in waits `warpEntryDelay`.
    private var wantsWarp = false
    private var warpEntry: Timer?
    private var running = false

    /// Called the moment the load asks for warp, `warpEntryDelay` before the
    /// sky goes to it: time for the cat to notice its ring and fly through it.
    var onWarpEntry: (() -> Void)?
    /// Called when the load no longer asks for warp: `fromWarp` is true if
    /// the sky had gone to it and has just stopped hard, false if it had not
    /// got there yet.
    var onWarpExit: ((_ fromWarp: Bool) -> Void)?
    /// The sky has finished braking and the cat can run again.
    var onBrakeEnd: (() -> Void)?
    /// The cat's "!" flashes this long, then the ring takes `ringApproach`
    /// to reach it.
    static let warpAlert: TimeInterval = 0.6
    static let ringApproach: TimeInterval = 0.35
    static let warpEntryDelay: TimeInterval = warpAlert + ringApproach

    /// How wide the strip out of sight is where stars are born.
    static let birthBand: CGFloat = 16
    /// Streaks are this many times as fast as the stars of their layer.
    private static let warpFactor: CGFloat = 8
    /// How much faster the stars still out go once warp starts, so the sky
    /// clears quickly for the streaks.
    private static let flingSpeed: Float = 8
    /// Leaves warp once the load has dropped this far below the threshold,
    /// so a load right at it doesn't flicker between the two.
    private static let hysteresis = 0.1

    /// The cat holds its braking pose as the stars slide left three times,
    /// coming to a complete stop after each slide. Times are real seconds.
    enum Brake {
        private struct Slide {
            let duration: CFTimeInterval
            let pause: CFTimeInterval
            /// How far a near star slides, in points.
            let distance: CGFloat
            /// Tail length at the end of the slide, in sprite pixels.
            let tail: Int
        }

        private static let slides = [
            Slide(duration: 0.20, pause: 0.14, distance: 24, tail: 10),
            Slide(duration: 0.16, pause: 0.17, distance: 12, tail: 5),
            Slide(duration: 0.12, pause: 0.20, distance: 6, tail: 0),
        ]
        static let cutTail = 24
        static let duration = slides.reduce(0) { $0 + $1.duration + $1.pause }

        struct Step {
            let time: CFTimeInterval
            let distance: CGFloat
            let tail: CGFloat
        }

        /// Move and shorten in discrete steps, then hold the last frame of
        /// each slide until the next one starts.
        static func steps(depth: CGFloat) -> [Step] {
            let pixel = PixelCatSprites.pixel
            func tailWidth(_ length: CGFloat) -> CGFloat { (length * depth).rounded() * pixel }
            var steps = [Step(time: 0, distance: 0, tail: tailWidth(CGFloat(cutTail)))]
            var start: CFTimeInterval = 0
            var distance: CGFloat = 0
            var tail = CGFloat(cutTail)
            for slide in slides {
                let pixels = max(1, Int((slide.distance * depth / pixel).rounded()))
                for step in 1...pixels {
                    let progress = Double(step) / Double(pixels)
                    steps.append(Step(
                        time: start + slide.duration * progress,
                        distance: distance + CGFloat(step) * pixel,
                        tail: tailWidth(tail + (CGFloat(slide.tail) - tail) * CGFloat(progress))
                    ))
                }
                start += slide.duration + slide.pause
                distance += CGFloat(pixels) * pixel
                tail = CGFloat(slide.tail)
            }
            return steps
        }
    }

    /// Further is smaller, dimmer and slower.
    private enum Depth {
        case dust, far, near

        var velocity: CGFloat {
            switch self {
            case .dust: 3.5
            case .far: 6
            case .near: 9
            }
        }

        /// Middle brightness, and how far a star may stray either side of it.
        var alpha: (CGFloat, Float) {
            switch self {
            case .dust: (0.3, 0.12)
            case .far: (0.55, 0.22)
            case .near: (0.85, 0.15)
            }
        }
    }

    private struct Kind {
        let name: String
        let depth: Depth
        let tint: Int
        let birthRate: Float
        let streak: Bool
    }

    /// The tints of the dust and far layers are born at rates that never
    /// fall in step, so two don't come in side by side. Near stars are big
    /// enough that even a near miss shows: their tints share one rate and
    /// take turns (see `nearStagger`), so they come in evenly spaced.
    private static let kinds = [
        Kind(name: "dust0", depth: .dust, tint: 0, birthRate: 0.29, streak: false),
        Kind(name: "dust2", depth: .dust, tint: 2, birthRate: 0.19, streak: false),
        Kind(name: "far0", depth: .far, tint: 0, birthRate: 0.17, streak: false),
        Kind(name: "far1", depth: .far, tint: 1, birthRate: 0.11, streak: false),
        Kind(name: "far2", depth: .far, tint: 2, birthRate: 0.07, streak: false),
        Kind(name: "near0", depth: .near, tint: 0, birthRate: 0.04, streak: false),
        Kind(name: "near1", depth: .near, tint: 1, birthRate: 0.04, streak: false),
        Kind(name: "near2", depth: .near, tint: 2, birthRate: 0.04, streak: false),
        Kind(name: "farStreak0", depth: .far, tint: 0, birthRate: 1.4, streak: true),
        Kind(name: "farStreak1", depth: .far, tint: 1, birthRate: 0.95, streak: true),
        Kind(name: "nearStreak0", depth: .near, tint: 0, birthRate: 0.7, streak: true),
        Kind(name: "nearStreak1", depth: .near, tint: 1, birthRate: 0.5, streak: true),
    ]

    init() {
        stars.emitterShape = .rectangle
        stars.emitterMode = .surface
        stars.renderMode = .unordered
        stars.birthRate = 0
        streaks.emitterShape = .rectangle
        streaks.emitterMode = .surface
        streaks.renderMode = .unordered
        streaks.birthRate = 0
        prefill.emitterShape = .rectangle
        prefill.emitterMode = .surface
        prefill.renderMode = .unordered
        prefill.birthRate = 0
        layer.addSublayer(prefill)
        layer.addSublayer(stars)
        layer.addSublayer(streaks)
        layer.addSublayer(brakingStars)
        layer.addSublayer(twinkles.layer)
        layer.addSublayer(meteors.layer)
    }

    /// `birthX` is the middle of the strip out of sight where stars are born;
    /// they drift left across `bounds`.
    func layout(bounds: CGRect, birthX: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        self.birthX = birthX
        for emitter in [stars, streaks] {
            emitter.frame = layer.bounds
            emitter.emitterPosition = CGPoint(x: birthX, y: layer.bounds.midY)
            emitter.emitterSize = CGSize(width: Self.birthBand, height: layer.bounds.height)
        }
        brakingStars.frame = layer.bounds
        prefill.frame = layer.bounds
        prefill.emitterPosition = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        prefill.emitterSize = layer.bounds.size
        twinkles.layer.frame = layer.bounds
        meteors.layer.frame = layer.bounds
        // Stars live as long as this sky is wide; the ones already out keep
        // their own lifetime.
        for kind in Self.kinds {
            guard kind.streak || braking == nil else { continue }
            guard let image = images[kind.name] else { continue }
            let emitter = kind.streak ? streaks : stars
            emitter.setValue(lifetime(kind, image: image), forKeyPath: "emitterCells.\(kind.name).lifetime")
        }
        CATransaction.commit()
        if running && needsPrefill { fillSky() }
        twinkles.releaseWaiting()
    }

    func setScale(_ scale: CGFloat) {
        let far = PixelCatSprites.starImages(scale: scale, near: false)
        let near = PixelCatSprites.starImages(scale: scale, near: true)
        let farStreaks = PixelCatSprites.streakImages(scale: scale, near: false)
        let nearStreaks = PixelCatSprites.streakImages(scale: scale, near: true)
        let dust = PixelCatSprites.dustImages(scale: scale)
        self.scale = scale
        images = [:]
        for kind in Self.kinds {
            let set: [CGImage] = switch (kind.depth, kind.streak) {
            case (.dust, _): dust
            case (.far, false): far
            case (.near, false): near
            case (.far, true): farStreaks
            case (.near, true): nearStreaks
            }
            if kind.tint < set.count { images[kind.name] = set[kind.tint] }
        }
        func cells(streak: Bool) -> [CAEmitterCell] {
            Self.kinds.filter { $0.streak == streak }.compactMap { kind in
                images[kind.name].map { cell(kind, image: $0, scale: scale) }
            }
        }
        if braking == nil { stars.emitterCells = cells(streak: false) }
        if running && needsPrefill { fillSky() }
        tailImages = PixelCatSprites.tailImages(scale: scale, length: Brake.cutTail)
        streaks.emitterCells = cells(streak: true)
        twinkles.setScale(scale)
        meteors.setScale(scale)
    }

    /// Fresh cells: an emitter keeps each cell's progress through a pause,
    /// and the near tints taking turns would come back in step.
    private func rebuildStarCells() {
        stars.emitterCells = Self.kinds.filter { !$0.streak }.compactMap { kind in
            images[kind.name].map { cell(kind, image: $0, scale: scale) }
        }
    }

    /// Fresh streak cells take the streaks still out with the old ones.
    private func clearStreaks() {
        streaks.emitterCells = Self.kinds.filter(\.streak).compactMap { kind in
            images[kind.name].map { cell(kind, image: $0, scale: scale) }
        }
    }

    func start() {
        guard !running else { return }
        running = true
        // Started in the layer's own time, so it begins with an empty sky
        // rather than a burst.
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        for emitter in [stars, streaks] {
            emitter.speed = 1
            emitter.timeOffset = 0
            emitter.beginTime = now
        }
        prefill.speed = 1
        prefill.timeOffset = 0
        rebuildStarCells()
        fillSky()
        twinkles.start()
        meteors.start()
        applyWarp()
    }

    func stop() {
        running = false
        warpEntry?.invalidate()
        warpEntry = nil
        wantsWarp = false
        warping = false
        braking?.invalidate()
        braking = nil
        removeBrakingStars()
        stars.birthRate = 0
        streaks.birthRate = 0
        prefill.birthRate = 0
        twinkles.stop()
        meteors.stop()
    }

    private func fillSky() {
        guard layer.bounds.width > 0, !images.isEmpty else {
            needsPrefill = true
            return
        }
        needsPrefill = false
        prefillHoldsStreaks = warping
        prefill.emitterCells = prefillCells()
        prefill.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        prefill.birthRate = 1
    }

    /// The same kinds of star, born all over the sky in one short moment,
    /// as many of each as are out at a time once the sky has filled.
    private func prefillCells() -> [CAEmitterCell] {
        let width = layer.bounds.width
        guard width > 0 else { return [] }
        return Self.kinds.filter { $0.streak == warping }.compactMap { kind in
            guard let image = images[kind.name] else { return nil }
            let cell = cell(kind, image: image, scale: scale)
            cell.beginTime = 0
            let count = Double(kind.birthRate) * Double(width / cell.velocity)
            cell.birthRate = Float(count / Self.prefillDuration)
            cell.duration = Self.prefillDuration
            return cell
        }
    }

    /// In warp the stars stop coming and the ones out rush off, twinkling
    /// ones too, while streaks pour in; out of it, the other way round.
    /// Twinkling and shooting stars wait for the brakes too.
    private func applyWarp() {
        guard running else { return }
        let interruptedBrake = warping && braking != nil
        if interruptedBrake {
            braking?.invalidate()
            braking = nil
            removeBrakingStars()
        }
        stars.birthRate = warping || braking != nil ? 0 : 1
        streaks.birthRate = warping ? 1 : 0
        // Birth rate only controls new particles. Hide the entire emitter
        // outside warp so any particles still held by the render server
        // cannot keep streaking through the braking pauses.
        streaks.isHidden = !warping
        stars.isHidden = braking != nil
        prefill.isHidden = braking != nil || (prefillHoldsStreaks && !warping)
        Self.retime(stars, to: warping ? Self.flingSpeed : 1)
        Self.retime(prefill, to: warping && !prefillHoldsStreaks ? Self.flingSpeed : 1)
        Self.retime(twinkles.layer, to: warping ? Self.flingSpeed : 1)
        twinkles.matchPace()
        Self.retime(brakingStars, to: brakingStarsSpeed, tolerance: 0)
        twinkles.setSuspended(warping || braking != nil)
        meteors.setSuspended(warping || braking != nil)
        if interruptedBrake { onBrakeEnd?() }
    }

    /// Flung in warp; while braking, whatever keeps them at the pace of the
    /// cut; after it, the sky's own.
    private var brakingStarsSpeed: Float {
        if warping { return Self.flingSpeed }
        if braking != nil { return brakePace / Self.effectiveSpeed(of: layer) }
        return 1
    }

    /// The sky's pace for this CPU load, given the pace of the layer it sits
    /// in, and warp past the threshold set in the settings.
    func update(load: Double, parentSpeed: Float) {
        guard running else { return }
        let load = min(max(load, 0), 1)
        let skySpeed = 1 + load * (Defaults[.rainbowCatSkyMaxSpeed] - 1)
        Self.retime(layer, to: Float(skySpeed) / max(parentSpeed, 0.01))
        twinkles.matchPace()
        if braking != nil { Self.retime(brakingStars, to: brakingStarsSpeed, tolerance: 0) }

        let threshold = Defaults[.rainbowCatWarpThreshold]
        let warp = Defaults[.rainbowCatWarp]
            && (wantsWarp ? load >= threshold - Self.hysteresis : load >= threshold)
        guard warp != wantsWarp else { return }
        wantsWarp = warp
        warpEntry?.invalidate()
        warpEntry = nil
        // A brake still going runs on through the "!" until warp starts.
        guard warp else {
            let fromWarp = warping
            warping = false
            // First, so the twinkling and shooting stars stay away.
            if fromWarp { stopHard() }
            applyWarp()
            onWarpExit?(fromWarp)
            return
        }
        onWarpEntry?()
        let timer = Timer(timeInterval: Self.warpEntryDelay, repeats: false) { [weak self] _ in
            guard let self, self.wantsWarp else { return }
            self.warpEntry = nil
            self.warping = true
            self.applyWarp()
        }
        RunLoop.main.add(timer, forMode: .common)
        warpEntry = timer
    }

    /// The braking stars supply the whole sky until the last pause ends.
    /// Clear any particles still out so nothing drifts through the pauses.
    private func stopHard() {
        guard running else { return }
        braking?.invalidate()
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: Brake.duration, repeats: false) { [weak self] _ in
            self?.endBrake()
        }
        braking = timer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        streaks.birthRate = 0
        clearStreaks()
        stars.birthRate = 0
        stars.emitterCells = nil
        prefill.birthRate = 0
        prefill.emitterCells = nil
        needsPrefill = false
        twinkles.stop()
        meteors.stop()
        putOutBrakingStars(at: start)
        CATransaction.commit()
        timer.fireDate = Date(timeIntervalSinceNow: max(0, Brake.duration - (CACurrentMediaTime() - start)))
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Resume births at the outer edge as the braking stars drift away.
    private func endBrake() {
        braking?.invalidate()
        braking = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stars.timeOffset = 0
        stars.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
        rebuildStarCells()
        // Start fresh so no twinkle or meteor can resume mid-flight.
        twinkles.start()
        meteors.start()
        applyWarp()
        CATransaction.commit()
        onBrakeEnd?()
    }

    private func removeBrakingStars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        brakingStars.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
    }

    /// Include enough sky beyond the edge for the slides to bring it into
    /// view. The right end meets the inner edge of the birth band as
    /// emission resumes.
    private func putOutBrakingStars(at start: CFTimeInterval) {
        removeBrakingStars()
        brakePace = Self.effectiveSpeed(of: layer)
        Self.retime(brakingStars, to: 1, tolerance: 0)
        let bounds = layer.bounds
        guard !layer.isHidden, bounds.width > 0, !images.isEmpty,
              tailImages.count == PixelCatSprites.starTints.count else { return }
        let pace = Double(brakePace)
        let populations = Self.kinds.filter { !$0.streak }.map { kind in
            let depth = kind.depth.velocity / Depth.near.velocity
            let steps = Brake.steps(depth: depth)
            let reach = max(0, birthX - Self.birthBand / 2 + (steps.last?.distance ?? 0))
            let count = Double(kind.birthRate) * Double(reach / kind.depth.velocity)
            return (kind: kind, steps: steps, reach: reach, count: count)
        }
        let expected = populations.reduce(0) { $0 + $1.count }
        let thinning = min(1, Double(Self.maxBrakingStars) / max(expected, 1))
        let now = brakingStars.convertTime(start, from: nil)
        for population in populations {
            guard let image = images[population.kind.name] else { continue }
            let count = population.count * thinning
            let whole = Int(count) + (Double.random(in: 0..<1) < count.truncatingRemainder(dividingBy: 1) ? 1 : 0)
            for _ in 0..<whole {
                addBrakingStar(
                    population.kind, image: image, x: .random(in: 0...population.reach),
                    steps: population.steps, pace: pace, at: now
                )
            }
        }
    }

    /// One star and its tail: the star crosses at the speed each beat gives,
    /// then at its own pace until it has left the sky, and is removed; the
    /// tail shortens a whole pixel at a time, from the star backwards.
    private func addBrakingStar(
        _ kind: Kind, image: CGImage, x startX: CGFloat,
        steps: [Brake.Step], pace: Double, at now: CFTimeInterval
    ) {
        let pixel = PixelCatSprites.pixel
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let velocity = kind.depth.velocity
        let star = CALayer()
        star.contents = image
        star.contentsScale = scale
        star.magnificationFilter = .nearest
        star.bounds = CGRect(origin: .zero, size: size)
        // Its edges on half pixels.
        let left = (startX - size.width / 2).rounded()
        let bottom = CGFloat.random(in: 0...max(0, layer.bounds.height - size.height)).rounded()
        let y = bottom + size.height / 2
        let (alpha, spread) = kind.depth.alpha
        star.opacity = Float(alpha) + .random(in: -spread...spread)

        let tail = CALayer()
        tail.contents = tailImages[kind.tint]
        tail.contentsScale = scale
        tail.magnificationFilter = .nearest
        tail.anchorPoint = CGPoint(x: 0, y: 0.5)
        // The near star's middle row; the others are no taller than that.
        tail.bounds = CGRect(x: 0, y: 0, width: 0, height: min(size.height, pixel))
        tail.position = CGPoint(x: size.width, y: size.height / 2)
        star.addSublayer(tail)

        let startX = left + size.width / 2
        let xs = steps.map { startX - $0.distance }
        let lastX = xs.last ?? startX
        let endX = -size.width
        star.position = CGPoint(x: endX, y: y)

        // Discrete key times include the end of the final held frame.
        let duration = Brake.duration * pace
        let keyTimes = steps.map { NSNumber(value: $0.time / Brake.duration) } + [1]
        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.values = xs
        move.keyTimes = keyTimes
        move.calculationMode = .discrete
        move.duration = duration

        let drift = CABasicAnimation(keyPath: "position.x")
        drift.fromValue = lastX
        drift.toValue = endX
        drift.beginTime = duration
        drift.duration = Double(max(0, lastX - endX) / velocity)

        let flight = CAAnimationGroup()
        flight.animations = lastX > endX ? [move, drift] : [move]
        flight.duration = duration + drift.duration
        flight.beginTime = now
        flight.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        flight.delegate = BrakingStarEnd(star: star)

        let shorten = CAKeyframeAnimation(keyPath: "bounds.size.width")
        shorten.values = steps.map(\.tail)
        shorten.keyTimes = keyTimes
        shorten.calculationMode = .discrete
        shorten.duration = duration
        shorten.beginTime = now

        brakingStars.addSublayer(star)
        star.add(flight, forKey: "brake")
        tail.add(shorten, forKey: "brake")
    }

    /// How fast a layer's time runs against the clock, its ancestors' speeds
    /// included.
    static func effectiveSpeed(of layer: CALayer) -> Float {
        var speed: Float = 1
        var current: CALayer? = layer
        while let each = current {
            speed *= each.speed
            current = each.superlayer
        }
        return max(speed, 0.01)
    }

    /// Changing a layer's speed mid-loop would jump; carrying its local time
    /// over keeps every animation and particle where it was. Changes within
    /// `tolerance` are skipped, so small load changes don't churn.
    static func retime(_ layer: CALayer, to speed: Float, tolerance: Float = 0.02) {
        guard abs(layer.speed - speed) > tolerance else { return }
        let now = CACurrentMediaTime()
        let parentTime = layer.superlayer?.convertTime(now, from: nil) ?? now
        let localTime = layer.convertTime(now, from: nil)
        layer.speed = speed
        layer.timeOffset = localTime
        layer.beginTime = parentTime
    }

    /// Dust is a dim point and slowest, far stars small and dim, near ones
    /// bigger, brighter and half again as fast; within a layer each star is
    /// a little brighter or dimmer than the next. Every star in a layer moves
    /// at the same speed, so they pass each other only across layers, as
    /// distance would have it.
    private func cell(_ kind: Kind, image: CGImage, scale: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.name = kind.name
        cell.contents = image
        cell.contentsScale = scale
        cell.magnificationFilter = CALayerContentsFilter.nearest.rawValue
        cell.birthRate = kind.birthRate
        cell.velocity = kind.depth.velocity * (kind.streak ? Self.warpFactor : 1)
        cell.emissionLongitude = .pi
        let (alpha, spread) = kind.streak ? (kind.depth == .near ? 1 : 0.55, 0) : kind.depth.alpha
        cell.color = NSColor(white: 1, alpha: alpha).cgColor
        cell.alphaRange = spread
        cell.lifetime = lifetime(kind, image: image)
        cell.beginTime = Self.nearStagger(kind)
        return cell
    }

    /// The near tints, one after another an even share of their period apart.
    private static func nearStagger(_ kind: Kind) -> CFTimeInterval {
        let near = kinds.filter { $0.depth == .near && !$0.streak }
        guard let index = near.firstIndex(where: { $0.name == kind.name }) else { return 0 }
        return Double(index) / Double(near.count) / Double(kind.birthRate)
    }

    /// Long enough to cross the birth band, the whole sky (a wing and the
    /// stretch behind the notch, or the settings' wider preview) and the
    /// star's own image, a streak's tail included.
    private func lifetime(_ kind: Kind, image: CGImage) -> Float {
        let velocity = kind.depth.velocity * (kind.streak ? Self.warpFactor : 1)
        let width = layer.bounds.width > 0 ? layer.bounds.width : 110
        return Float((width + Self.birthBand + 4 + CGFloat(image.width) / scale) / velocity)
    }
}

/// Takes a braking star away once it has left the sky. One removed with
/// the others (the sky stopped, or braking again) is gone already.
private final class BrakingStarEnd: NSObject, CAAnimationDelegate {
    private weak var star: CALayer?

    init(star: CALayer) {
        self.star = star
    }

    func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        guard finished, let star else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        star.removeFromSuperlayer()
        CATransaction.commit()
    }
}
