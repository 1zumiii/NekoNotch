//
//  RainbowCatNSView+Notes.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The notes the cat sings while media plays, planned by NoteScheduler,
//  and how loud the music is, when they follow it.
//
import AppKit
import QuartzCore

extension RainbowCatNSView {
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
    func setLoudness(_ loudness: Float) {
        guard isPlaying, !reducesMotion, abs(loudness - lastLoudness) >= 0.08 else { return }
        lastLoudness = loudness
        notesPerSecond = Double(0.95 + 1.8 * loudness) * 1.08
    }

    // MARK: Notes

    private var stageTime: Double { stage.convertTime(CACurrentMediaTime(), from: nil) }

    /// The first note comes at once; the rest at the pace `NoteScheduler` sets.
    func startNotes() {
        guard noteTimer == nil, warpTransition == nil, !isBraking else { return }
        pruneNotes()
        if noteLayers.isEmpty { noteScheduler.reset() }
        spawnNote()
    }

    /// Notes already in the air rise on out of sight unless `clearing`.
    func stopNotes(clearing: Bool) {
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
