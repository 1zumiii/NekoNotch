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
    /// A pale blue glow over the whole sky for a moment as warp ends.
    private let flash = CALayer()
    /// Steps the stars back down to their pace after a hard stop.
    private var braking: Timer?
    /// Coming out of warp the stars are this many times as fast, slowing to
    /// their own pace over `brakeSteps`.
    private static let brakeSpeeds: [Float] = [3, 2.4, 1.9, 1.5, 1.2, 1.05, 1]
    private static let brakeStep: TimeInterval = 0.05
    private var images: [String: CGImage] = [:]
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
        flash.backgroundColor = CGColor(red: 0.75, green: 0.88, blue: 1, alpha: 1)
        flash.opacity = 0
        layer.addSublayer(flash)
        layer.addSublayer(prefill)
        layer.addSublayer(stars)
        layer.addSublayer(streaks)
        layer.addSublayer(twinkles.layer)
        layer.addSublayer(meteors.layer)
    }

    /// `birthX` is the middle of the strip out of sight where stars are born;
    /// they drift left across `bounds`.
    func layout(bounds: CGRect, birthX: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        for emitter in [stars, streaks] {
            emitter.frame = layer.bounds
            emitter.emitterPosition = CGPoint(x: birthX, y: layer.bounds.midY)
            emitter.emitterSize = CGSize(width: Self.birthBand, height: layer.bounds.height)
        }
        flash.frame = layer.bounds
        prefill.frame = layer.bounds
        prefill.emitterPosition = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        prefill.emitterSize = layer.bounds.size
        twinkles.layer.frame = layer.bounds
        meteors.layer.frame = layer.bounds
        // Stars live as long as this sky is wide; the ones already out keep
        // their own lifetime.
        for kind in Self.kinds {
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
        stars.emitterCells = cells(streak: false)
        if running && needsPrefill { fillSky() }
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
        braking?.invalidate()
        braking = nil
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
    private func applyWarp() {
        guard running else { return }
        stars.birthRate = warping ? 0 : 1
        streaks.birthRate = warping ? 1 : 0
        Self.retime(stars, to: warping ? Self.flingSpeed : 1)
        Self.retime(prefill, to: warping && !prefillHoldsStreaks ? Self.flingSpeed : 1)
        Self.retime(twinkles.layer, to: warping ? Self.flingSpeed : 1)
        twinkles.setSuspended(warping)
        meteors.setSuspended(warping)
    }

    /// The sky's pace for this CPU load, given the pace of the layer it sits
    /// in, and warp past the threshold set in the settings.
    func update(load: Double, parentSpeed: Float) {
        let load = min(max(load, 0), 1)
        let skySpeed = 1 + load * (Defaults[.rainbowCatSkyMaxSpeed] - 1)
        Self.retime(layer, to: Float(skySpeed) / max(parentSpeed, 0.01))

        let threshold = Defaults[.rainbowCatWarpThreshold]
        let warp = Defaults[.rainbowCatWarp]
            && (wantsWarp ? load >= threshold - Self.hysteresis : load >= threshold)
        guard warp != wantsWarp else { return }
        wantsWarp = warp
        warpEntry?.invalidate()
        warpEntry = nil
        braking?.invalidate()
        braking = nil
        guard warp else {
            let fromWarp = warping
            warping = false
            applyWarp()
            if fromWarp { stopHard() }
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

    /// Out of warp the way films do it: a flash, the streaks gone at once,
    /// and a sky full of stars still rushing by, braking to their own pace.
    private func stopHard() {
        guard running else { return }
        clearStreaks()
        fillSky()

        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [0, 0.35, 0]
        glow.keyTimes = [0, 0.3, 1]
        glow.duration = 0.25
        glow.speed = 1 / Self.effectiveSpeed(of: layer)
        flash.add(glow, forKey: "flash")

        var steps = Self.brakeSpeeds[...]
        func brake() {
            guard let speed = steps.popFirst() else {
                braking?.invalidate()
                braking = nil
                return
            }
            Self.retime(stars, to: speed)
            Self.retime(prefill, to: speed)
            Self.retime(twinkles.layer, to: speed)
        }
        brake()
        let timer = Timer(timeInterval: Self.brakeStep, repeats: true) { _ in brake() }
        RunLoop.main.add(timer, forMode: .common)
        braking = timer
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
    /// over keeps every animation and particle where it was.
    static func retime(_ layer: CALayer, to speed: Float) {
        guard abs(layer.speed - speed) > 0.02 else { return }
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
