//
//  RainbowCatNSView+Warp.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The cat's way into warp ("!", then through the ring) and out of it
//  (bracing and braced while the sky brakes, the rainbow flung up).
//
import AppKit
import QuartzCore

extension RainbowCatNSView {
    // MARK: Warp

    /// The cat sees the ring coming ("!"), flies through it and the sky goes
    /// to warp; it stops singing until then.
    func beginWarpTransition() {
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

    func clearWarpTransition() {
        warpTransition?.invalidate()
        warpTransition = nil
        alert.removeAnimation(forKey: Self.alertKey)
        ringBack.removeAnimation(forKey: Self.ringKey)
        ringFront.removeAnimation(forKey: Self.ringKey)
    }

    /// The load dropped before the ring reached the cat: no ring, no warp.
    func cancelWarpTransition() {
        guard warpTransition != nil else { return }
        let speed = 1 / max(stage.speed, 0.1)
        Self.fadeOut(alert, forKey: Self.alertKey, speed: speed)
        Self.fadeOut(ringBack, forKey: Self.ringKey, speed: speed)
        Self.fadeOut(ringFront, forKey: Self.ringKey, speed: speed)
        WarpRingFlight.shared.announce(nil)
        endWarpTransition()
    }

    /// How long a cancelled ring or "!" takes to fade out.
    static let cancelFade: CFTimeInterval = 0.15

    /// A ring or "!" that is showing stops where it is and fades out, rather
    /// than vanishing; one not showing yet just goes. `speed` makes it real
    /// time in the layer's parent.
    static func fadeOut(_ layer: CALayer, forKey key: String, speed: Float) {
        guard layer.animation(forKey: key) != nil else { return }
        let shown = layer.presentation()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Hidden once the fade is over, whatever was animating it.
        layer.opacity = 0
        CATransaction.commit()
        guard let shown, shown.opacity > 0.01 else {
            layer.removeAnimation(forKey: key)
            return
        }
        let hold = CABasicAnimation(keyPath: "position")
        hold.fromValue = NSValue(point: shown.position)
        hold.toValue = hold.fromValue
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shown.opacity
        fade.toValue = 0
        let out = CAAnimationGroup()
        out.animations = [hold, fade]
        out.duration = cancelFade
        out.speed = speed
        // Under the same key, so it takes the place of the flight.
        layer.add(out, forKey: key)
    }

    /// The cat stays planted in its crouch until the sky's last pause ends.
    func brake() {
        guard window != nil, !reducesMotion, brakeImages.count == 2 else { return }
        isBraking = true
        stopNotes(clearing: false)
        updateCatAnimation(through: Self.braceIn)
        flingTrail()
    }

    /// The rainbow can't stop at once either: it flicks up a pixel, half a
    /// pixel at a time, and settles, the flick running back from the cat.
    /// On top of the wave, in real time whatever pace the stage keeps.
    private func flingTrail() {
        let now = CACurrentMediaTime()
        let half = Self.pixel / 2
        for (index, segment) in segments.enumerated() {
            let flick = CAKeyframeAnimation(keyPath: "position.y")
            flick.values = [0, half, 2 * half, 2 * half, half, 0]
            flick.calculationMode = .discrete
            flick.isAdditive = true
            flick.duration = 0.45
            flick.speed = 1 / max(stage.speed, 0.1)
            flick.beginTime = segment.convertTime(now + Double(index) * 0.025, from: nil)
            segment.add(flick, forKey: "fling")
        }
    }

    func finishBrake() {
        guard isBraking else { return }
        isBraking = false
        updateCatAnimation(through: Self.braceOut)
        if isPlaying && !reducesMotion { startNotes() }
    }

    /// Running or braced; `through` shows the bracing frame that long
    /// first, in real time, between the two.
    func updateCatAnimation(through: CFTimeInterval = 0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cat.removeAnimation(forKey: Self.runKey)
        cat.removeAnimation(forKey: Self.braceKey)
        cat.contents = isBraking ? brakeImages.last : catImages.first
        let pace = Double(max(stage.speed, 0.1))
        if through > 0, let bracing = brakeImages.first, !reducesMotion {
            let hold = CAKeyframeAnimation(keyPath: "contents")
            hold.values = [bracing]
            hold.calculationMode = .discrete
            hold.duration = through * pace
            cat.add(hold, forKey: Self.braceKey)
        }
        if !isBraking && !reducesMotion {
            let run = runAnimation()
            run.beginTime = cat.convertTime(CACurrentMediaTime(), from: nil) + through * pace
            cat.add(run, forKey: Self.runKey)
        }
        CATransaction.commit()
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
}
