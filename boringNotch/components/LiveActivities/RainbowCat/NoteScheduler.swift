//
//  NoteScheduler.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Plans the notes that rise from the singing cat's head: when the next one
//  comes, which way it leans, how fast it rises and how it sways. The
//  directions take turns, each note picks its angle at random within its
//  half, and a note is placed where it keeps clear of the ones still in the
//  air leaning the same way, for as long as both are there. Notes leaning
//  opposite ways share the head they come from, so they may cross.
//

import CoreGraphics
import Foundation

struct NoteScheduler {
    /// One note's flight, in the stage's time and coordinates.
    struct Note: Equatable {
        var birth: Double
        var origin: CGPoint
        /// Radians from the positive x axis; up is π/2.
        var angle: Double
        var speed: Double
        var swayAmplitude: Double
        var swayPeriod: Double
        var swayPhase: Double

        /// Straight out along its angle, swaying from side to side across it.
        func position(at time: Double) -> CGPoint {
            let age = time - birth
            let along = speed * age
            let sway = swayAmplitude * sin(2 * .pi * age / swayPeriod + swayPhase)
            return CGPoint(
                x: origin.x + along * cos(angle) - sway * sin(angle),
                y: origin.y + along * sin(angle) + sway * cos(angle)
            )
        }

        /// 1 back, -1 forward.
        var leaning: Double { angle > .pi / 2 ? 1 : -1 }

        func isAlive(at time: Double) -> Bool { time < birth + NoteScheduler.lifetime }
    }

    static let lifetime: Double = 2.4
    /// A note with its outline, a little trimmed for the empty corners of
    /// its sprite: two notes closer than this on both axes overlap.
    static let footprint = CGSize(width: 7.5, height: 8.5)
    /// Each half's middle, in radians from straight up, and how far either
    /// side of it a note may lean.
    static let halfCentre: Double = 0.45
    static let halfSpread: Double = 0.3
    static let speeds: ClosedRange<Double> = 8...10
    /// A note fades in over this long as it leaves the head; until then it
    /// is too faint to count as in the way.
    static let fadeIn: Double = 0.35
    static let colourCount = 6
    /// Random tries at a note that keeps clear before waiting for room.
    static let attempts = 8
    /// How long to wait for room before trying again.
    static let retryDelay: Double = 0.1

    private(set) var live: [Note] = []
    /// 1 leans back (left, behind the running cat), -1 forward.
    private(set) var nextLeaning: Double = 1
    private var recentColours: [Int] = []

    /// The time until the next note: around one over `rate`, give or take
    /// 40%, and never so soon that two come at once.
    static func interval<R: RandomNumberGenerator>(rate: Double, using rng: inout R) -> Double {
        max(0.3, 1 / max(rate, 0.01) * Double.random(in: 0.6...1.4, using: &rng))
    }

    /// Plans the note born at `time` from `head`, and the colour to draw it
    /// in; nil when none of a few random tries would keep clear of the notes
    /// in the air leaning the same way, and the caller tries again after `retryDelay`. Keeping
    /// clear comes first: when the music asks for notes faster than they
    /// fit, they come as fast as they fit.
    mutating func next<R: RandomNumberGenerator>(
        at time: Double, from head: CGPoint, using rng: inout R
    ) -> (note: Note, colour: Int)? {
        live.removeAll { !$0.isAlive(at: time) }
        let leaning = nextLeaning
        let sameWay = live.filter { $0.leaning == leaning }
        for _ in 0..<Self.attempts {
            let lean = Self.halfCentre + Double.random(in: -Self.halfSpread...Self.halfSpread, using: &rng)
            let candidate = Note(
                birth: time,
                origin: head,
                angle: .pi / 2 + leaning * lean,
                speed: Double.random(in: Self.speeds, using: &rng),
                swayAmplitude: Double.random(in: 0.6...1.4, using: &rng),
                swayPeriod: Double.random(in: 1.6...2.6, using: &rng),
                swayPhase: Double.random(in: 0..<(2 * .pi), using: &rng)
            )
            guard Self.closestGap(of: candidate, to: sameWay) >= 0 else { continue }
            nextLeaning = -leaning
            live.append(candidate)
            return (candidate, nextColour(using: &rng))
        }
        return nil
    }

    mutating func reset() {
        live.removeAll()
        recentColours.removeAll()
    }

    /// The smallest gap between `note` and any of `others` while both are in
    /// the air, once the younger has faded in: negative where they overlap.
    static func closestGap(of note: Note, to others: [Note]) -> Double {
        var nearest = Double.infinity
        for other in others {
            let end = min(note.birth, other.birth) + lifetime
            let start = max(note.birth, other.birth) + fadeIn
            guard end > start else { continue }
            let steps = 16
            for step in 0...steps {
                let time = start + (end - start) * Double(step) / Double(steps)
                let a = note.position(at: time), b = other.position(at: time)
                let gap = max(abs(a.x - b.x) - footprint.width, abs(a.y - b.y) - footprint.height)
                nearest = min(nearest, gap)
            }
        }
        return nearest
    }

    /// Any colour but the last two, so the same one never comes close together.
    private mutating func nextColour<R: RandomNumberGenerator>(using rng: inout R) -> Int {
        let choices = (0..<Self.colourCount).filter { !recentColours.contains($0) }
        let colour = choices.randomElement(using: &rng) ?? 0
        recentColours.append(colour)
        if recentColours.count > 2 { recentColours.removeFirst() }
        return colour
    }
}
