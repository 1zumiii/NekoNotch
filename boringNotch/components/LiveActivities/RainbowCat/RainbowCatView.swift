//
//  RainbowCatView.swift
//  boringNotch
//
//  The pixel cat in the closed notch. Everything that moves is Core
//  Animation on one stage layer: the render server flips the frames and
//  moves the notes by itself, and the app does no per-frame work (it only
//  plans each note as it is born, a couple of times a second). The
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
    static let pixel = PixelCatSprites.pixel
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

    let stage = CALayer()
    let cat = CALayer()
    var segments: [CALayer] = []
    let notes = CALayer()
    var noteScheduler = NoteScheduler()
    var noteLayers: [(layer: CALayer, note: NoteScheduler.Note)] = []
    var noteTimer: Timer?
    var notesPerSecond: Double = 2
    /// Just above the head, a little behind the nose, in the stage's coordinates.
    var noteHead: CGPoint = .zero
    private let sky = StarSky()
    /// The ring the cat flies through into warp: one half behind it, one in front.
    let ringBack = CALayer()
    let ringFront = CALayer()
    static let ringKey = "ring"
    /// The "!" over the cat's head when it sees the ring coming.
    let alert = CALayer()
    static let alertKey = "alert"
    /// From the "!" until the sky has gone to warp: the cat stops singing.
    var warpTransition: Timer?
    private var stripeImage: CGImage?
    var noteImages: [CGImage] = []

    var isPlaying = false
    /// Off where one sky lies behind the whole scene instead (the settings'
    /// preview), so there is no seam where this one would fade.
    private var showsSky = true
    var useRealtime = false
    private var isActive = true
    var lastLoudness: Float = -1
    weak var attachedManager: AudioCaptureManager?
    var renderedScale: CGFloat = 0
    var catImages: [CGImage] = []
    /// The instant of bracing, then braced (see `PixelCatSprites.brakeImages`).
    var brakeImages: [CGImage] = []
    /// How long the bracing frame shows on the way into the brace and on
    /// the way out of it.
    static let braceIn: CFTimeInterval = 0.08
    static let braceOut: CFTimeInterval = 0.12
    var isBraking = false

    /// Four frames at rest take this long; the CPU load speeds it up to
    /// three times as fast.
    private static let baseCycle: CFTimeInterval = 1.2
    static let runKey = "run"
    static let braceKey = "brace"
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

        stage.addSublayer(sky.layer)

        cat.magnificationFilter = .nearest
        stage.addSublayer(cat)
        // Above the cat: the notes come from its head.
        stage.addSublayer(notes)
        for ring in [ringBack, ringFront] {
            ring.magnificationFilter = .nearest
            ring.opacity = 0
        }
        stage.insertSublayer(ringBack, below: cat)
        stage.insertSublayer(ringFront, above: cat)
        alert.magnificationFilter = .nearest
        alert.opacity = 0
        stage.addSublayer(alert)
        sky.onWarpEntry = { [weak self] in self?.beginWarpTransition() }
        sky.onWarpExit = { [weak self] fromWarp in
            if fromWarp { self?.brake() } else { self?.cancelWarpTransition() }
        }
        sky.onBrakeEnd = { [weak self] in self?.finishBrake() }
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
        let ringSize = CGSize(
            width: CGFloat(PixelCatSprites.warpRingRows[0].count) * Self.pixel,
            height: CGFloat(PixelCatSprites.warpRingRows.count) * Self.pixel
        )
        for ring in [ringBack, ringFront] {
            ring.bounds = CGRect(origin: .zero, size: ringSize)
            ring.position = CGPoint(x: stage.bounds.maxX + ringSize.width, y: cat.frame.midY)
        }
        // Over the right ear: its middle on the head's last column, its foot
        // a half pixel above the ear.
        let alertSize = CGSize(
            width: CGFloat(PixelCatSprites.alertRows[0].count) + 1,
            height: CGFloat(PixelCatSprites.alertRows.count) + 1
        )
        alert.bounds = CGRect(origin: .zero, size: alertSize)
        alert.position = CGPoint(
            x: catOrigin.x + (CGFloat(PixelCatSprites.width) - 0.5) * Self.pixel,
            y: catOrigin.y + CGFloat(PixelCatSprites.height - 3) * Self.pixel + 1.5 + alertSize.height / 2
        )
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
        notes.frame = stage.bounds
        noteHead = CGPoint(
            x: catOrigin.x + 14 * Self.pixel,
            y: catOrigin.y + CGFloat(PixelCatSprites.height - 3) * Self.pixel
        )
        // Stars come in over the outer edge and drift left, out of sight
        // behind the notch. They are born anywhere in a band out of sight,
        // so they don't line up in columns.
        sky.layout(bounds: stage.bounds, birthX: stage.bounds.maxX + 2 * Self.pixel + StarSky.birthBand / 2)
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
            restartAnimations()
            CPULoadMonitor.shared.observe(self) { [weak self] load in self?.setCPULoad(load) }
        } else {
            CPULoadMonitor.shared.stopObserving(self)
            isBraking = false
            clearWarpTransition()
            cat.removeAllAnimations()
            segments.forEach { $0.removeAllAnimations() }
            stopNotes(clearing: true)
            sky.stop()
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
        brakeImages = PixelCatSprites.brakeImages(scale: scale)
        stripeImage = PixelCatSprites.stripeImage(scale: scale)
        let rings = PixelCatSprites.warpRingImages(scale: scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringBack.contentsScale = scale
        ringBack.contents = rings?.back
        ringFront.contentsScale = scale
        ringFront.contents = rings?.front
        alert.contentsScale = scale
        alert.contents = PixelCatSprites.alertImage(scale: scale)
        cat.contentsScale = scale
        cat.contents = isBraking ? brakeImages.last : catImages.first
        for segment in segments {
            segment.contentsScale = scale
            segment.contents = stripeImage
        }
        noteImages = PixelCatSprites.noteImages(scale: scale)
        CATransaction.commit()
        sky.setScale(scale)
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

    func setShowsSky(_ shows: Bool) {
        guard shows != showsSky else { return }
        showsSky = shows
        restartAnimations()
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
    /// The cat and the sky each speed up as far as the settings say.
    private func setCPULoad(_ load: Double) {
        guard !reducesMotion else { return }
        let speed = Float(1 + CPULoadMonitor.pace(for: load) * (Defaults[.rainbowCatMaxSpeed] - 1))
        StarSky.retime(stage, to: speed)
        sky.update(load: load, parentSpeed: stage.speed)
    }

    var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Animations

    private func restartAnimations() {
        guard window != nil, !catImages.isEmpty else { return }
        let reducesMotion = self.reducesMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sky.layer.isHidden = reducesMotion || !showsSky
        for segment in segments {
            segment.removeAnimation(forKey: Self.waveKey)
            segment.position.y = trailCenterY
        }
        CATransaction.commit()
        if reducesMotion {
            isBraking = false
            clearWarpTransition()
            sky.stop()
        } else {
            sky.start()
        }
        updateCatAnimation()

        if isPlaying && !reducesMotion {
            setLoudness(useRealtime ? 0.3 : 0.5)
            startNotes()
        } else {
            stopNotes(clearing: false)
        }

        guard !reducesMotion else { return }
        for (index, segment) in segments.enumerated() {
            segment.add(waveAnimation(column: index), forKey: Self.waveKey)
        }
    }

    private var frameRates: CAFrameRateRange { CAFrameRateRange(minimum: 4, maximum: 15, preferred: 8) }

    func runAnimation() -> CAKeyframeAnimation {
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

}

struct RainbowCat: NSViewRepresentable {
    /// True while media plays: the cat sings, notes rising from its head.
    var isPlaying = false
    /// False when this cat isn't on screen.
    var isActive = true
    /// False where a sky of its own lies behind the cat.
    var showsSky = true
    @Default(.realtimeAudioWaveform) private var realtimeEnabled
    @Default(.rainbowCatNotesFollowVolume) private var notesFollowVolume
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
        // Levels are only computed for someone who asks: an idle cat, or one
        // whose notes keep a steady pace, doesn't.
        let followsVolume = notesFollowVolume && realtimeEnabled
        view.setActive(isActive && isPlaying && followsVolume)
        view.setUseRealtime(followsVolume && audioCapture.isCapturing)
        view.setPlaying(isPlaying)
        view.setShowsSky(showsSky)
    }
}
