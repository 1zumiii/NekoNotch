//
//  PixelCatSprites+Effects.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  What the cat gives off: the notes it sings, the "!" it flashes and the
//  ring it flies through on its way into warp.
//
import CoreGraphics
import Foundation

extension PixelCatSprites {
    private static let notes: [[String]] = [
        [
            "..X..",
            "..XX.",
            "..X.X",
            "..X..",
            ".XX..",
            "XXX..",
            "XX...",
        ],
        [
            ".XXXXX",
            ".X...X",
            ".X...X",
            ".X...X",
            "XX..XX",
            "XX..XX",
        ],
    ]

    /// The ring the cat flies through on its way into warp, seen from the
    /// side: a bright cyan rim with deep blue inside it. Split into the half
    /// behind the cat and the half in front, the same size so they line up.
    static let warpRingRows = [
        "..BBB..",
        ".BBDBB.",
        ".BD.DB.",
        "BD...DB",
        "BD...DB",
        "BD...DB",
        "BD...DB",
        "BD...DB",
        "BD...DB",
        "BD...DB",
        ".BD.DB.",
        ".BBDBB.",
        "..BBB..",
    ]

    /// A red "!" in half pixels with the notes' white outline, flashed over
    /// the cat's head when it sees the warp ring coming.
    static let alertRows = ["XX", "XX", "XX", "XX", "XX", "XX", "..", "XX"]

    static func alertImage(scale: CGFloat) -> CGImage? {
        outlinedImage(rows: alertRows, scale: scale, color: (0.95, 0.16, 0.18))
    }

    static func warpRingImages(scale: CGFloat) -> (back: CGImage, front: CGImage)? {
        let middle = (warpRingRows.first?.count ?? 0) / 2
        func half(front: Bool) -> CGImage? {
            let rows = warpRingRows.map { row in
                String(row.enumerated().map { column, character in (column >= middle) == front ? character : "." })
            }
            return image(rows: rows, scale: scale) { character in
                switch character {
                case "B": (0.45, 0.88, 1.0)
                case "D": (0.16, 0.42, 1.0)
                default: nil
                }
            }
        }
        guard let back = half(front: false), let front = half(front: true) else { return nil }
        return (back, front)
    }

    /// Music notes in each rainbow colour, single and beamed in turn: one
    /// point a pixel with a half-point white outline (two device pixels and
    /// one, on Retina), so they stand out against the dark notch.
    static func noteImages(scale: CGFloat) -> [CGImage] {
        rainbow.enumerated().compactMap { index, color in
            outlinedImage(rows: notes[index % notes.count], scale: scale, color: color)
        }
    }
}
