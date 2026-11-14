//
//  NoteSchedulerTests.swift
//  boringNotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import XCTest
@testable import boringNotch

final class NoteSchedulerTests: XCTestCase {
    /// A seeded generator, so a failing run can be repeated.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Two minutes of notes at the steady pace and at full volume.
    private func plan(rate: Double, seed: UInt64) -> [(note: NoteScheduler.Note, colour: Int)] {
        var rng = SplitMix(state: seed)
        var scheduler = NoteScheduler()
        var time = 0.0
        var notes: [(note: NoteScheduler.Note, colour: Int)] = []
        while time < 120 {
            if let planned = scheduler.next(at: time, from: .zero, using: &rng) {
                notes.append(planned)
                time += NoteScheduler.interval(rate: rate, using: &rng)
            } else {
                time += NoteScheduler.retryDelay
            }
        }
        return notes
    }

    func testDirectionsTakeTurnsAndStayInTheirHalf() {
        let notes = plan(rate: 2, seed: 1).map(\.note)
        for (index, note) in notes.enumerated() {
            let lean = note.angle - .pi / 2
            let expected: Double = index % 2 == 0 ? 1 : -1
            XCTAssertEqual(lean.sign == .minus ? -1 : 1, expected, "note \(index) leans the wrong way")
            XCTAssertEqual(abs(lean), NoteScheduler.halfCentre, accuracy: NoteScheduler.halfSpread + 1e-9)
        }
    }

    func testIntervalsVaryButNeverBunchUp() {
        var rng = SplitMix(state: 2)
        let waits = (0..<500).map { _ in NoteScheduler.interval(rate: 2, using: &rng) }
        XCTAssertGreaterThanOrEqual(waits.min()!, 0.3)
        XCTAssertGreaterThan(waits.max()! - waits.min()!, 0.2, "the pace should not be even")
    }

    func testColourNeverRepeatsWithinTwo() {
        let colours = plan(rate: 2, seed: 3).map(\.colour)
        for index in 2..<colours.count {
            XCTAssertNotEqual(colours[index], colours[index - 1])
            XCTAssertNotEqual(colours[index], colours[index - 2])
        }
    }

    /// No two notes leaning the same way overlap, even when the music asks
    /// for more than fit; they come as fast as they fit instead.
    func testNotesLeaningTheSameWayNeverOverlap() {
        for rate in [1.0, 2.0, 3.0] {
            let notes = plan(rate: rate, seed: 4).map(\.note)
            for index in notes.indices {
                let earlier = notes[..<index].filter { $0.isAlive(at: notes[index].birth) && $0.leaning == notes[index].leaning }
                XCTAssertGreaterThanOrEqual(NoteScheduler.closestGap(of: notes[index], to: Array(earlier)), 0, "rate \(rate): note \(index) overlaps")
            }
            XCTAssertGreaterThan(Double(notes.count) / 120, min(rate, 1.5) * 0.85, "rate \(rate): too few notes")
        }
    }
}
