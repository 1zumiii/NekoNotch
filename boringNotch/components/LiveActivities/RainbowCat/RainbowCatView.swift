//
//  RainbowCatView.swift
//  boringNotch
//
//  The pixel cat in the closed notch. Everything that moves is Core
//  Animation on one stage layer: the render server flips the frames and
//  moves the notes by itself, and the app does no per-frame work. The
//  stage's speed follows the CPU load, so the cat runs faster when the Mac
//  is busy.
//
//  The view is a window onto a wider sky, not a frame: the rainbow runs on
//  past its left edge and stars drift by behind the cat. While media plays
//  the cat sings as it runs: coloured notes rise from its head and float
//  up out of sight, more of them the louder the music is.
//
import AppKit
import Defaults
import SwiftUI

final class RainbowCatNSView: NSView, AudioCaptureLevelsConsumer {
    private static let pixel = PixelCatSprites.pixel
    private static let catSize = CGSize(
        width: CGFloat(PixelCatSprites.width) * pixel,
        height: CGFloat(PixelCatSprites.height) * pixel
    )
    /// Columns of rainbow behind the keyboard, enough to run past the
    /// window's inner edge, as if from behind the notch. The first ones run
    /// under the tail.
    private static let trailColumns = 24
    /// How far the window reaches in past the view, over the black margin
    /// beside the cutout, so the rainbow meets the notch itself.
    static let innerReach = liveActivityEdgeMargin
    /// The rainbow visible inside the wing, in columns.
    private static let visibleColumns = 5
    /// The rainbow and the sky fade out over this width at the window's
    /// inner edge, instead of being cut off against the notch.
    static let fadeWidth: CGFloat = 10

    /// A mask for a window's inner edge: clear at that edge, opaque
    /// `fadeWidth` into the window.
    static func innerEdgeFade(width: CGFloat, height: CGFloat, innerEdgeOnLeft: Bool) -> CAGradientLayer {
        let mask = CAGradientLayer()
        mask.frame = CGRect(x: 0, y: 0, width: width, height: height)
        mask.startPoint = CGPoint(x: innerEdgeOnLeft ? 0 : 1, y: 0.5)
        mask.endPoint = CGPoint(x: innerEdgeOnLeft ? 1 : 0, y: 0.5)
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        mask.locations = [0, NSNumber(value: Double(min(fadeWidth / max(width, 1), 1)))]
        return mask
    }
    /// Where the keyboard starts within the cat's frame.
    private static let bodyInset = CGFloat(PixelCatSprites.bodyLeftColumn) * pixel
    private static let groupWidth = catSize.width - bodyInset + CGFloat(visibleColumns) * pixel
    /// Room right of the cat; the rainbow runs to the wing's left edge.
    private static let rightMargin: CGFloat = 2
    /// The width of the cat's wing of the closed notch: a window onto its
    /// sky, just wide enough for the cat and its rainbow.
    static let wingWidth = groupWidth + rightMargin
    /// What the settings preview shows.
    static let size = CGSize(width: wingWidth, height: 30)
    /// One turn of the trail's wave, in columns.
    private static let waveLength = 8

    private let stage = CALayer()
    private let cat = CALayer()
    private var segments: [CALayer] = []
    private let notes = CAEmitterLayer()
    private let stars = CAEmitterLayer()
    private var stripeImage: CGImage?

    private var isPlaying = false
    private var useRealtime = false
    private var isActive = true
    private var lastLoudness: Float = -1
    private weak var attachedManager: AudioCaptureManager?
    private var renderedScale: CGFloat = 0
    private var catImages: [CGImage] = []

    /// Four frames at rest take this long; the CPU load speeds it up to
    /// three times as fast.
    private static let baseCycle: CFTimeInterval = 1.2
    private static let maxSpeedUp: Double = 2
    private static let runKey = "run"
    private static let waveKey = "wave"

    /// Where the cat stands: near the outer edge, on whole pixels.
    /// In the stage's coordinates, which start `innerReach` left of the view.
    private var catOrigin: CGPoint {
        CGPoint(
            x: ((bounds.width - Self.catSize.width - Self.rightMargin) / Self.pixel).rounded(.down) * Self.pixel + Self.innerReach,
            y: ((bounds.height - Self.catSize.height) / 2 / Self.pixel).rounded() * Self.pixel
        )
    }

    private var trailHeight: CGFloat { CGFloat(PixelCatSprites.stripeCount) * Self.pixel }

    /// The keyboard's rows, where the trail runs.
    private var trailCenterY: CGFloat {
        let rows = PixelCatSprites.bodyRows
        let middleFromTop = CGFloat(rows.lowerBound + rows.upperBound + 1) / 2
        return catOrigin.y + (CGFloat(PixelCatSprites.height) - middleFromTop) * Self.pixel
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(stage)
        stage.masksToBounds = true

        stars.emitterShape = .rectangle
        stars.emitterMode = .surface
        stars.renderMode = .unordered
        stage.addSublayer(stars)

        notes.emitterShape = .point
        notes.renderMode = .unordered
        notes.birthRate = 0

        cat.magnificationFilter = .nearest
        stage.addSublayer(cat)
        // Above the cat: the notes come from its head.
        stage.addSublayer(notes)
    }

    /// Lays everything out for the view's size: the trail gets as many
    /// segments as reach past the left edge.
    private var laidOutSize: CGSize = .zero

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The stage reaches in over the margin beside the cutout; it clips
        // the rainbow and the sky there.
        stage.frame = CGRect(x: -Self.innerReach, y: 0, width: bounds.width + Self.innerReach, height: bounds.height)
        stage.mask = Self.innerEdgeFade(width: stage.bounds.width, height: stage.bounds.height, innerEdgeOnLeft: true)
        cat.frame = CGRect(origin: catOrigin, size: Self.catSize)
        if segments.isEmpty {
            segments = (0..<Self.trailColumns).map { index in
                let segment = CALayer()
                segment.magnificationFilter = .nearest
                segment.contentsScale = renderedScale
                segment.contents = stripeImage
                stage.insertSublayer(segment, below: cat)
                return segment
            }
        }
        for (index, segment) in segments.enumerated() {
            segment.bounds = CGRect(x: 0, y: 0, width: Self.pixel, height: trailHeight)
            // Counted from the keyboard's back edge, so the joint stays in place.
            segment.position = CGPoint(x: catOrigin.x + Self.bodyInset - (CGFloat(index) + 0.5) * Self.pixel, y: trailCenterY)
        }
        // Just above the head, a little behind the nose.
        notes.emitterPosition = CGPoint(
            x: catOrigin.x + 14 * Self.pixel,
            y: catOrigin.y + CGFloat(PixelCatSprites.height - 3) * Self.pixel
        )
        // Stars come in over the outer edge and drift left, out of sight
        // behind the notch.
        stars.emitterPosition = CGPoint(x: stage.bounds.maxX + 2 * Self.pixel, y: stage.bounds.midY)
        stars.emitterSize = CGSize(width: 1, height: stage.bounds.height)
        CATransaction.commit()
        restartAnimations()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { Self.size }

    deinit {
        attachedManager?.clearLevelsConsumer(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            renderImages()
            CPULoadMonitor.shared.observe(self) { [weak self] load in self?.setCPULoad(load) }
            restartAnimations()
        } else {
            CPULoadMonitor.shared.stopObserving(self)
            cat.removeAllAnimations()
            segments.forEach { $0.removeAllAnimations() }
            notes.birthRate = 0
            stars.birthRate = 0
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderImages()
        restartAnimations()
    }

    private func renderImages() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard scale != renderedScale else { return }
        renderedScale = scale
        catImages = PixelCatSprites.catImages(scale: scale)
        stripeImage = PixelCatSprites.stripeImage(scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cat.contentsScale = scale
        cat.contents = catImages.first
        for segment in segments {
            segment.contentsScale = scale
            segment.contents = stripeImage
        }
        // Twelve kinds of note (six colours, two directions) at one rate,
        // started at evenly spaced times: one note at a time, the colours in
        // turn and the directions taking turns.
        let images = PixelCatSprites.noteImages(scale: scale)
        let kinds = images.count * 2
        notes.emitterCells = (0..<kinds).map { index in
            let cell = Self.noteCell(images[index % images.count], scale: scale, leaning: index % 2 == 0 ? 1 : -1)
            cell.beginTime = Double(index) / Double(kinds) / Double(cell.birthRate)
            return cell
        }
        stars.emitterCells = Self.starCells(scale: scale)
        CATransaction.commit()
    }

    /// Two layers of sky for depth: far stars are small, dim and slow, near
    /// ones bigger, brighter and twice as fast. Every star in a layer moves
    /// at the same speed, so they pass each other only across layers, as
    /// distance would have it.
    static func starCells(scale: CGFloat) -> [CAEmitterCell] {
        let far = PixelCatSprites.starImages(scale: scale, near: false).map { image in
            starCell(image, scale: scale, velocity: 6, alpha: 0.55, birthRate: 0.3)
        }
        let near = PixelCatSprites.starImages(scale: scale, near: true).map { image in
            starCell(image, scale: scale, velocity: 9, alpha: 1, birthRate: 0.12)
        }
        return far + near
    }

    private static func starCell(
        _ image: CGImage, scale: CGFloat, velocity: CGFloat, alpha: Float, birthRate: Float
    ) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image
        cell.contentsScale = scale
        cell.magnificationFilter = CALayerContentsFilter.nearest.rawValue
        cell.birthRate = birthRate
        cell.velocity = velocity
        cell.emissionLongitude = .pi
        cell.color = NSColor(white: 1, alpha: CGFloat(alpha)).cgColor
        // Long enough to cross a wing and the stretch behind the notch.
        cell.lifetime = Float(110 / velocity)
        return cell
    }

    /// Notes rise from the head and float up out of the window, half of
    /// them up and back (`leaning` 1), half up and forward (-1).
    private static func noteCell(_ image: CGImage, scale: CGFloat, leaning: CGFloat) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.contents = image
        cell.contentsScale = scale
        cell.magnificationFilter = CALayerContentsFilter.nearest.rawValue
        // Shared out between six colours and two directions; the layer's
        // rate scales it.
        cell.birthRate = 0.09
        cell.lifetime = 2.4
        cell.velocity = 9
        cell.velocityRange = 2
        cell.emissionLongitude = .pi / 2 + leaning * 0.45
        cell.emissionRange = 0.25
        cell.alphaSpeed = -0.25
        return cell
    }

    // MARK: State from SwiftUI

    func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        lastLoudness = -1
        restartAnimations()
    }

    func setUseRealtime(_ enabled: Bool) {
        guard useRealtime != enabled else { return }
        useRealtime = enabled
        lastLoudness = -1
        restartAnimations()
    }

    func attach(to manager: AudioCaptureManager) {
        guard attachedManager !== manager else { return }
        attachedManager?.clearLevelsConsumer(self)
        attachedManager = manager
        if isActive { manager.setLevelsConsumer(self) }
    }

    /// An inactive view asks for no levels, so none are computed for it.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        guard let manager = attachedManager else { return }
        if active { manager.setLevelsConsumer(self) } else { manager.clearLevelsConsumer(self) }
    }

    // MARK: Pace

    /// Changing a layer's speed mid-loop would jump; carrying its local time
    /// over keeps every animation where it was.
    private func setCPULoad(_ load: Double) {
        guard !reducesMotion else { return }
        let speed = Float(1 + min(max(load, 0), 1) * Self.maxSpeedUp)
        guard abs(stage.speed - speed) > 0.05 else { return }
        let now = CACurrentMediaTime()
        let localTime = stage.convertTime(now, from: nil)
        stage.speed = speed
        stage.timeOffset = localTime
        stage.beginTime = now
    }

    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Animations

    private func restartAnimations() {
        guard window != nil, !catImages.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cat.removeAnimation(forKey: Self.runKey)
        for segment in segments {
            segment.removeAnimation(forKey: Self.waveKey)
            segment.position.y = trailCenterY
        }
        CATransaction.commit()
        stars.birthRate = reducesMotion ? 0 : 1

        if isPlaying && !reducesMotion {
            // Started in the stage's own time, without a burst of notes
            // left over from the last time.
            notes.beginTime = stage.convertTime(CACurrentMediaTime(), from: nil)
            notes.birthRate = 1
            setLoudness(useRealtime ? 0.3 : 0.5)
        } else {
            notes.birthRate = 0
        }

        guard !reducesMotion else {
            cat.contents = catImages.first
            return
        }
        cat.add(runAnimation(), forKey: Self.runKey)
        for (index, segment) in segments.enumerated() {
            segment.add(waveAnimation(column: index), forKey: Self.waveKey)
        }
    }

    private var frameRates: CAFrameRateRange { CAFrameRateRange(minimum: 4, maximum: 15, preferred: 8) }

    private func runAnimation() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = catImages
        animation.calculationMode = .discrete
        animation.duration = Self.baseCycle
        animation.repeatCount = .infinity
        animation.preferredFrameRateRange = frameRates
        return animation
    }

    /// A gentle wave flowing back along the rainbow: each column follows a
    /// sine rounded to three heights (up, level, down) half a pixel apart,
    /// one column further on every step.
    private func waveAnimation(column: Int) -> CAKeyframeAnimation {
        let length = Self.waveLength
        let animation = CAKeyframeAnimation(keyPath: "position.y")
        animation.values = (0..<length).map { step in
            let angle = 2 * Double.pi * Double(column - step) / Double(length)
            // Half a sprite pixel: still two whole device pixels on Retina.
            return trailCenterY + CGFloat(sin(angle).rounded()) * Self.pixel / 2
        }
        animation.calculationMode = .discrete
        // Two steps per frame of the legs.
        animation.duration = Self.baseCycle * Double(length) / 8
        animation.repeatCount = .infinity
        animation.preferredFrameRateRange = frameRates
        return animation
    }

    // MARK: Loudness

    func syncCurrentLevels(from manager: AudioCaptureManager) {
        guard attachedManager === manager, let values = manager.latestLevelsSnapshot() else { return }
        applyLevels(values)
    }

    func audioCaptureManager(_ manager: AudioCaptureManager, didProduceLevels values: [Float]) {
        applyLevels(values)
    }

    private func applyLevels(_ values: [Float]) {
        guard isPlaying, useRealtime, !values.isEmpty else { return }
        let loudness = min(max(values.reduce(0, +) / Float(values.count), 0), 1)
        setLoudness(loudness)
    }

    /// Louder music, more notes: about one a second when it is quiet, three
    /// a second at full volume. Only a clear change is
    /// passed on, so the emitter isn't touched every frame.
    private func setLoudness(_ loudness: Float) {
        guard isPlaying, !reducesMotion, abs(loudness - lastLoudness) >= 0.08 else { return }
        lastLoudness = loudness
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notes.birthRate = 0.95 + 1.8 * loudness
        CATransaction.commit()
    }
}

struct RainbowCat: NSViewRepresentable {
    /// True while media plays: the cat sings, notes rising from its head.
    var isPlaying = false
    /// False when this cat isn't on screen.
    var isActive = true
    @Default(.realtimeAudioWaveform) private var realtimeEnabled
    @ObservedObject private var audioCapture = AudioCaptureManager.shared

    func makeNSView(context: Context) -> RainbowCatNSView {
        let view = RainbowCatNSView(frame: CGRect(origin: .zero, size: RainbowCatNSView.size))
        update(view)
        view.attach(to: audioCapture)
        view.syncCurrentLevels(from: audioCapture)
        return view
    }

    func updateNSView(_ view: RainbowCatNSView, context: Context) {
        update(view)
        view.syncCurrentLevels(from: audioCapture)
    }

    private func update(_ view: RainbowCatNSView) {
        // Levels are only computed for someone who asks: an idle cat doesn't.
        view.setActive(isActive && isPlaying)
        view.setUseRealtime(realtimeEnabled && audioCapture.isCapturing)
        view.setPlaying(isPlaying)
    }
}

/// The empty wing opposite the cat: the same sky drifting by, so the closed
/// notch looks alike on both sides.
final class StarfieldNSView: NSView {
    private let stage = CALayer()
    private let stars = CAEmitterLayer()
    private var renderedScale: CGFloat = 0
    private static let maxSpeedUp: Double = 2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(stage)
        stage.masksToBounds = true
        stars.emitterShape = .rectangle
        stars.emitterMode = .surface
        stars.renderMode = .unordered
        stage.addSublayer(stars)
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
        stars.emitterPosition = CGPoint(x: stage.bounds.maxX, y: stage.bounds.midY)
        stars.emitterSize = CGSize(width: 1, height: stage.bounds.height)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            CPULoadMonitor.shared.stopObserving(self)
            stars.birthRate = 0
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        if scale != renderedScale {
            renderedScale = scale
            stars.emitterCells = RainbowCatNSView.starCells(scale: scale)
        }
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        stars.beginTime = stage.convertTime(CACurrentMediaTime(), from: nil)
        stars.birthRate = reducesMotion ? 0 : 1
        guard !reducesMotion else { return }
        CPULoadMonitor.shared.observe(self) { [weak self] load in self?.setCPULoad(load) }
    }

    /// The sky goes by as fast as the cat runs.
    private func setCPULoad(_ load: Double) {
        let speed = Float(1 + min(max(load, 0), 1) * Self.maxSpeedUp)
        guard abs(stage.speed - speed) > 0.05 else { return }
        let now = CACurrentMediaTime()
        let localTime = stage.convertTime(now, from: nil)
        stage.speed = speed
        stage.timeOffset = localTime
        stage.beginTime = now
    }
}

struct RainbowStars: NSViewRepresentable {
    func makeNSView(context: Context) -> StarfieldNSView { StarfieldNSView(frame: .zero) }
    func updateNSView(_ view: StarfieldNSView, context: Context) {}
}
