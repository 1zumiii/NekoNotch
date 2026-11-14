//
//  PixelCatSprites+Brake.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The cat braking out of warp: the poses on the way into the brace and
//  the brace itself, put together on a grid of half pixels.
//
import CoreGraphics
import Foundation

extension PixelCatSprites {
    // MARK: Braking

    // Braking out of warp the cat sits back and braces: the keyboard leans
    // back, rear down on the ground, the head comes up, the forelegs go out
    // stiff in front and the tail is flung forward over its back. Braking
    // poses are put together on a grid of half pixels, so the keyboard can
    // rise in steps of half a pixel.

    /// How many slices the keyboard is cut into as it leans back. Each
    /// steps up from the one behind it, so more slices make a smoother
    /// slope; the rise is 2 pixels in all, so past 5 some steps are flat.
    static let brakeSlices = 5

    /// One pose on the way into the brace, or the brace itself. `seat` and
    /// `front` are the top of the keyboard's back and front slices in half
    /// pixels, the slices between stepping evenly from one to the other;
    /// the head and `fur` (legs, paws, tail) are in whole pixels. `squeeze`
    /// is how many half pixels the keyboard is pressed shorter by, taken
    /// evenly from inside it: the back edge stays on the rainbow and the
    /// front draws back.
    private struct BrakePose {
        let seat: Int
        let front: Int
        let squeeze: Int
        let head: (row: Int, column: Int)
        let fur: [(Int, Int)]
    }

    /// The tail straight up from the back edge, before it swings forward.
    private static let tailRaised = [(4, 2), (3, 2), (2, 2), (1, 2), (0, 2)]

    /// The first instant: the seat going down, the forepaws thrust out in
    /// front, the head not up yet but the face already screwed up.
    private static let bracing = BrakePose(
        seat: 4, front: 2, squeeze: 1,
        head: (headOrigin.row, headOrigin.column),
        fur: [(9, 16), (9, 17), (9, 14)] + tailRaised
    )

    /// Sat back and braced: the head up with the front of the keyboard and
    /// drawn back a pixel, the forelegs straight and slanting forward from
    /// under the chin, a hind paw planted in front of the seat, the tail
    /// turned forward over the back.
    private static let braced = BrakePose(
        seat: 4, front: 0, squeeze: 2,
        head: (headOrigin.row - 1, headOrigin.column - 1),
        fur: [(8, 15), (8, 16), (9, 16), (9, 17), (8, 13), (9, 14)]
            + [(9, 7), (9, 8)]
            + tailRaised + [(0, 3), (0, 4)]
    )

    /// Screwed shut against the jolt, in half pixels from the head's row
    /// above the eyes: "> <".
    private static let squintEyes = [
        "..............",
        "..X........X..",
        "...X......X...",
        "..X........X..",
    ]

    private static let eyeRow = 2

    /// The mouth pinched into a small caret where the "ω" was.
    private static let grittedMouth = [
        "......",
        "..XX..",
        ".X..X.",
    ]

    /// A braking pose laid out in half pixels, its corners bevelled.
    private static func halfGrid(_ pose: BrakePose) -> [String] {
        var grid = [[Character]](repeating: [Character](repeating: ".", count: width * 2), count: height * 2)
        func put(_ character: Character, _ row: Int, _ column: Int) {
            guard grid.indices.contains(row), grid[row].indices.contains(column) else { return }
            grid[row][column] = character
        }
        func pixel(_ character: Character, _ row: Int, _ column: Int) {
            for dr in 0..<2 { for dc in 0..<2 { put(character, row * 2 + dr, column * 2 + dc) } }
        }

        let columns = body[0].count
        let slices = max(1, min(brakeSlices, columns))
        let edges = (0...slices).map { $0 * columns / slices }
        let tops = (0..<columns).map { column in
            let slice = edges.lastIndex { $0 <= column } ?? 0
            let t = slices == 1 ? 0 : Double(slice) / Double(slices - 1)
            return Int((Double(pose.seat) + Double(pose.front - pose.seat) * t).rounded())
        }
        // The keyboard in half columns, less the squeezed ones: spread
        // evenly between the frame's two-half-column ends.
        let halves = columns * 2
        let inside = halves - 4
        let squeezed = Set((0..<max(0, min(pose.squeeze, inside))).map { 2 + ($0 + 1) * inside / (pose.squeeze + 1) })
        let kept = (0..<halves).filter { !squeezed.contains($0) }
        let keys = body.map(Array.init)
        for (index, half) in kept.enumerated() {
            let column = half / 2
            for (row, line) in keys.enumerated() {
                for dr in 0..<2 { put(line[column], tops[column] + row * 2 + dr, bodyLeftColumn * 2 + index) }
            }
        }
        for (row, line) in head.enumerated() {
            for (column, character) in line.enumerated() where character != "." {
                pixel(character == "K" ? "G" : character, pose.head.row + row, pose.head.column + column)
            }
        }
        for (row, column) in pose.fur { pixel("G", row, column) }

        let mouthAt = (row: pose.head.row + mouthOrigin.row - headOrigin.row,
                       column: pose.head.column + mouthOrigin.column - headOrigin.column)
        for (pattern, at) in [(squintEyes, (row: pose.head.row + eyeRow, column: pose.head.column)), (grittedMouth, mouthAt)] {
            for (row, line) in pattern.enumerated() {
                for (column, character) in line.enumerated() where character == "X" {
                    put("K", at.row * 2 + row, at.column * 2 + column)
                }
            }
        }

        // A slight bevel: half a pixel off every outside corner of the
        // keyboard's frame, the steps of its slope included.
        let frame = grid
        func empty(_ row: Int, _ column: Int) -> Bool {
            !frame.indices.contains(row) || !frame[row].indices.contains(column) || frame[row][column] == "."
        }
        for row in frame.indices {
            for column in frame[row].indices where frame[row][column] == "D" {
                let up = empty(row - 1, column), down = empty(row + 1, column)
                let left = empty(row, column - 1), right = empty(row, column + 1)
                if (up || down) && (left || right) { grid[row][column] = "." }
            }
        }
        return grid.map { String($0) }
    }

    /// The braking poses as images: the instant of bracing, then braced.
    static func brakeImages(scale: CGFloat) -> [CGImage] {
        [bracing, braced].compactMap { pose in
            image(rows: halfGrid(pose), scale: scale / 2, color: { palette[$0] })
        }
    }
}
