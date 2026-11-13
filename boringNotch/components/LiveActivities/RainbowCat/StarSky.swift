//
//  StarSky.swift
//  boringNotch
//
//  The sky behind the rainbow cat, and the empty wing opposite it: emitted
//  stars in two layers of depth, a few that twinkle, and, once the CPU is
//  busy enough, streaks of light as if the cat had gone to warp speed.
//  Its layer keeps its own pace, set from the CPU load and the settings, so
//  the sky can speed up more than the cat does.
//
import AppKit
import Defaults
import QuartzCore

final class StarSky {
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
    private var images: [String: CGImage] = [:]
    private var scale: CGFloat = 2
    private var warping = false
    private var running = false

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

    private struct Kind {
        let name: String
        let near: Bool
        let tint: Int
        let birthRate: Float
        let streak: Bool
    }

    /// The white and the yellow star of a layer are born at rates that never
    /// fall in step, so the two don't come in side by side.
    private static let kinds = [
        Kind(name: "far0", near: false, tint: 0, birthRate: 0.17, streak: false),
        Kind(name: "far1", near: false, tint: 1, birthRate: 0.13, streak: false),
        Kind(name: "near0", near: true, tint: 0, birthRate: 0.07, streak: false),
        Kind(name: "near1", near: true, tint: 1, birthRate: 0.05, streak: false),
        Kind(name: "farStreak0", near: false, tint: 0, birthRate: 1.4, streak: true),
        Kind(name: "farStreak1", near: false, tint: 1, birthRate: 0.95, streak: true),
        Kind(name: "nearStreak0", near: true, tint: 0, birthRate: 0.7, streak: true),
        Kind(name: "nearStreak1", near: true, tint: 1, birthRate: 0.5, streak: true),
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
        layer.addSublayer(twinkles.layer)
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
        prefill.frame = layer.bounds
        prefill.emitterPosition = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        prefill.emitterSize = layer.bounds.size
        twinkles.layer.frame = layer.bounds
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
        self.scale = scale
        images = [:]
        for kind in Self.kinds {
            let set = kind.streak ? (kind.near ? nearStreaks : farStreaks) : (kind.near ? near : far)
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
        fillSky()
        twinkles.start()
        applyWarp()
    }

    func stop() {
        running = false
        stars.birthRate = 0
        streaks.birthRate = 0
        prefill.birthRate = 0
        twinkles.stop()
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
    }

    /// The sky's pace for this CPU load, given the pace of the layer it sits
    /// in, and warp past the threshold set in the settings.
    func update(load: Double, parentSpeed: Float) {
        let load = min(max(load, 0), 1)
        let skySpeed = 1 + load * (Defaults[.rainbowCatSkyMaxSpeed] - 1)
        Self.retime(layer, to: Float(skySpeed) / max(parentSpeed, 0.01))

        let threshold = Defaults[.rainbowCatWarpThreshold]
        let warp = Defaults[.rainbowCatWarp]
            && (warping ? load >= threshold - Self.hysteresis : load >= threshold)
        guard warp != warping else { return }
        warping = warp
        applyWarp()
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

    /// Far stars are small, dim and slow, near ones bigger, brighter and half
    /// again as fast. Every star in a layer moves at the same speed, so they
    /// pass each other only across layers, as distance would have it.
    private func cell(_ kind: Kind, image: CGImage, scale: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.name = kind.name
        cell.contents = image
        cell.contentsScale = scale
        cell.magnificationFilter = CALayerContentsFilter.nearest.rawValue
        cell.birthRate = kind.birthRate
        let velocity: CGFloat = (kind.near ? 9 : 6) * (kind.streak ? Self.warpFactor : 1)
        cell.velocity = velocity
        cell.emissionLongitude = .pi
        cell.color = NSColor(white: 1, alpha: kind.near ? 1 : 0.55).cgColor
        cell.lifetime = lifetime(kind, image: image)
        return cell
    }

    /// Long enough to cross the birth band, the whole sky (a wing and the
    /// stretch behind the notch, or the settings' wider preview) and the
    /// star's own image, a streak's tail included.
    private func lifetime(_ kind: Kind, image: CGImage) -> Float {
        let velocity: CGFloat = (kind.near ? 9 : 6) * (kind.streak ? Self.warpFactor : 1)
        let width = layer.bounds.width > 0 ? layer.bounds.width : 110
        return Float((width + Self.birthBand + 4 + CGFloat(image.width) / scale) / velocity)
    }
}
