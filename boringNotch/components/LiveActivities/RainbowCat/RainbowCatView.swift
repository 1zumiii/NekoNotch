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
    private let notes = CALayer()
    private var noteScheduler = NoteScheduler()
    private var noteLayers: [(layer: CALayer, note: NoteScheduler.Note)] = []
    private var noteTimer: Timer?
    private var notesPerSecond: Double = 2
    /// Just above the head, a little behind the nose, in the stage's coordinates.
    private var noteHead: CGPoint = .zero
    private let sky = StarSky()
    /// The ring the cat flies through into warp: one half behind it, one in front.
    private let ringBack = CALayer()
    private let ringFront = CALayer()
    private static let ringKey = "ring"
    /// The "!" over the cat's head when it sees the ring coming.
    private let alert = CALayer()
    private static let alertKey = "alert"
    /// From the "!" until the sky has gone to warp: the cat stops singing.
    private var warpTransition: Timer?
    private var stripeImage: CGImage?
    private var noteImages: [CGImage] = []

    private var isPlaying = false
    /// Off where one sky lies behind the whole scene instead (the settings'
    /// preview), so there is no seam where this one would fade.
    private var showsSky = true
    private var useRealtime = false
    private var isActive = true
    private var lastLoudness: Float = -1
    private weak var attachedManager: AudioCaptureManager?
    private var renderedScale: CGFloat = 0
    private var catImages: [CGImage] = []

    /// Four frames at rest take this long; the CPU load speeds it up to
    /// three times as fast.
    private static let baseCycle: CFTimeInterval = 1.2
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
            if fromWarp { self?.lurch() } else { self?.cancelWarpTransition() }
        }
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
            CPULoadMonitor.shared.observe(self) { [weak self] load in self?.setCPULoad(load) }
            restartAnimations()
        } else {
            CPULoadMonitor.shared.stopObserving(self)
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
        cat.contents = catImages.first
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
        sky.layer.isHidden = !shows
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
        let speed = Float(1 + min(max(load, 0), 1) * (Defaults[.rainbowCatMaxSpeed] - 1))
        StarSky.retime(stage, to: speed)
        sky.update(load: load, parentSpeed: stage.speed)
    }

    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Warp

    /// The cat sees the ring coming ("!"), flies through it and the sky goes
    /// to warp; it stops singing until then.
    private func beginWarpTransition() {
        guard window != nil, !reducesMotion, ringBack.contents != nil else { return }
        warpTransition?.invalidate()
        stopNotes(clearing: false)
        let timer = Timer(timeInterval: StarSky.warpEntryDelay, repeats: false) { [weak self] _ in
            self?.endWarpTransition()
        }
        RunLoop.main.add(timer, forMode: .common)
        warpTransition = timer
        flashAlert()
        flyThroughRing()
    }

    private func endWarpTransition() {
        warpTransition?.invalidate()
        warpTransition = nil
        if isPlaying && !reducesMotion { startNotes() }
    }

    /// The load dropped before the ring reached the cat: no ring, no warp.
    private func cancelWarpTransition() {
        guard warpTransition != nil else { return }
        alert.removeAnimation(forKey: Self.alertKey)
        ringBack.removeAnimation(forKey: Self.ringKey)
        ringFront.removeAnimation(forKey: Self.ringKey)
        WarpRingFlight.shared.announce(nil)
        endWarpTransition()
    }

    /// Out of warp the cat and its rainbow can't stop at once: they run on
    /// two pixels, a half pixel at a time, and settle back past their place.
    private func lurch() {
        guard window != nil, !reducesMotion else { return }
        let shove = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shove.values = [0, 1, 2, 3, 4, 4, 3, 2, 1, 0, -1, 0]
        shove.calculationMode = .discrete
        shove.duration = 0.4
        shove.speed = 1 / max(stage.speed, 0.1)
        for layer in [cat] + segments {
            layer.add(shove, forKey: "lurch")
        }
    }

    /// Three quick flashes, in real time whatever pace the stage keeps.
    private func flashAlert() {
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [1, 0, 1, 0, 1, 0]
        flash.keyTimes = (0...5).map { NSNumber(value: Double($0) / 6) }
        flash.calculationMode = .discrete
        flash.duration = StarSky.warpAlert
        flash.speed = 1 / max(stage.speed, 0.1)
        alert.add(flash, forKey: Self.alertKey)
    }

    /// Once the "!" is done the ring comes in from beyond the outer edge,
    /// faster and faster, and passes over the cat just as the sky goes to
    /// warp; then the cat leaves it behind faster still, and it rushes back
    /// behind the notch and out across the empty wing (see `WarpRingFlight`).
    /// In real time, whatever pace the stage keeps, so it meets the sky's switch.
    private func flyThroughRing() {
        guard let window, let space = WarpRingFlight.Space(stage, in: window) else { return }
        let ringWidth = ringBack.bounds.width
        let startX = stage.bounds.maxX + ringWidth / 2
        let catX = cat.frame.midX
        let exitX = -ringWidth / 2

        let now = CACurrentMediaTime()
        let arrive = now + StarSky.warpAlert
        let pass = WarpRingFlight.Pass(
            window: ObjectIdentifier(window),
            x: space.root(catX),
            time: arrive + StarSky.ringApproach,
            // Speeding up evenly from rest, it reaches the cat going twice
            // its average speed.
            speed: 2 * (startX - catX) / StarSky.ringApproach * space.scale,
            acceleration: WarpRingFlight.acceleration * space.scale
        )
        let leave = pass.time(atX: space.root(exitX))
        WarpRingFlight.shared.announce(pass)

        let approachSteps = 8
        let approach: [CGFloat] = (0..<approachSteps).map { step in
            let u = CGFloat(step) / CGFloat(approachSteps)
            return startX - (startX - catX) * u * u
        }
        let away = pass.keyframes(from: pass.time, to: leave, in: space, steps: 12)
        let total = leave - arrive
        let approachShare = StarSky.ringApproach / total
        var times = (0..<approachSteps).map { Double($0) / Double(approachSteps) * approachShare }
        times += (0...12).map { approachShare + (1 - approachShare) * Double($0) / 12 }

        let move = CAKeyframeAnimation(keyPath: "position.x")
        move.values = approach + away
        move.keyTimes = times.map { NSNumber(value: $0) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1]
        fade.keyTimes = [0, NSNumber(value: approachShare * 0.3), 1]
        let flight = CAAnimationGroup()
        flight.animations = [move, fade]
        flight.duration = total
        flight.speed = 1 / max(stage.speed, 0.1)
        flight.beginTime = ringBack.convertTime(arrive, from: nil)
        flight.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        for ring in [ringBack, ringFront] {
            ring.add(flight, forKey: Self.ringKey)
        }
    }

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
        if reducesMotion || !showsSky { sky.stop() } else { sky.start() }

        if isPlaying && !reducesMotion {
            setLoudness(useRealtime ? 0.3 : 0.5)
            startNotes()
        } else {
            stopNotes(clearing: false)
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
    /// a second at full volume. The next note to be planned takes it up.
    private func setLoudness(_ loudness: Float) {
        guard isPlaying, !reducesMotion, abs(loudness - lastLoudness) >= 0.08 else { return }
        lastLoudness = loudness
        notesPerSecond = Double(0.95 + 1.8 * loudness) * 1.08
    }

    // MARK: Notes

    private var stageTime: Double { stage.convertTime(CACurrentMediaTime(), from: nil) }

    /// The first note comes at once; the rest at the pace `NoteScheduler` sets.
    private func startNotes() {
        guard noteTimer == nil, warpTransition == nil else { return }
        pruneNotes()
        if noteLayers.isEmpty { noteScheduler.reset() }
        spawnNote()
    }

    /// Notes already in the air rise on out of sight unless `clearing`.
    private func stopNotes(clearing: Bool) {
        noteTimer?.invalidate()
        noteTimer = nil
        guard clearing else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        noteLayers.forEach { $0.layer.removeFromSuperlayer() }
        CATransaction.commit()
        noteLayers.removeAll()
        noteScheduler.reset()
    }

    private func pruneNotes() {
        let now = stageTime
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        noteLayers.removeAll { entry in
            guard !entry.note.isAlive(at: now) else { return false }
            entry.layer.removeFromSuperlayer()
            return true
        }
        CATransaction.commit()
    }

    private func spawnNote() {
        noteTimer = nil
        guard isPlaying, !reducesMotion, window != nil, !noteImages.isEmpty else { return }
        pruneNotes()
        var rng = SystemRandomNumberGenerator()
        let wait: Double
        if let (note, colour) = noteScheduler.next(at: stageTime, from: noteHead, using: &rng) {
            addLayer(for: note, image: noteImages[colour % noteImages.count])
            wait = NoteScheduler.interval(rate: notesPerSecond, using: &rng)
        } else {
            // No room yet: the notes in the air will have moved on soon.
            wait = NoteScheduler.retryDelay
        }
        // The plan is in the stage's time, which runs faster under load.
        let timer = Timer(timeInterval: wait / Double(max(stage.speed, 0.1)), repeats: false) { [weak self] _ in self?.spawnNote() }
        RunLoop.main.add(timer, forMode: .common)
        noteTimer = timer
    }

    /// Fades in as it leaves the head, rises along the planned path, fading
    /// again as it goes, then stays hidden until it is pruned.
    private func addLayer(for note: NoteScheduler.Note, image: CGImage) {
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = renderedScale
        layer.magnificationFilter = .nearest
        layer.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / renderedScale, height: CGFloat(image.height) / renderedScale)
        layer.position = note.origin
        layer.opacity = 0

        let steps = 24
        let path = CAKeyframeAnimation(keyPath: "position")
        path.values = (0...steps).map { step in
            NSValue(point: note.position(at: note.birth + NoteScheduler.lifetime * Double(step) / Double(steps)))
        }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0.4]
        fade.keyTimes = [0, NSNumber(value: NoteScheduler.fadeIn / NoteScheduler.lifetime), 1]
        let flight = CAAnimationGroup()
        flight.animations = [path, fade]
        flight.duration = NoteScheduler.lifetime
        flight.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notes.addSublayer(layer)
        layer.add(flight, forKey: "flight")
        CATransaction.commit()
        noteLayers.append((layer, note))
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
            ring.removeAnimation(forKey: Self.ringKey)
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
