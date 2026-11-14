//
//  PixelCatSprites.swift
//  boringNotch
//
//  An original pixel cat with a piano keyboard for a body, laid out the way
//  the rainbow-cat fan art usually is: a grey head low at the front, four
//  stubby paws underneath, the tail at the back. Frames are
//  drawn once into small images; Core Animation flips between them, so
//  drawing costs nothing per frame.
//
//  This file holds the cat's parts, its running frames and the drawing
//  helpers; the braking poses, the sky's sprites and the other effects are
//  in PixelCatSprites+Brake, +Sky and +Effects.
//
import CoreGraphics
import Foundation

enum PixelCatSprites {
    /// One sprite pixel in points: four device pixels on Retina.
    static let pixel: CGFloat = 2

    static let width = 18

    static let height = 10

    /// The keyboard starts this many columns in; the tail sticks out to its
    /// left, over the rainbow.
    static let bodyLeftColumn = 3

    /// Rows of the frame the keyboard covers (from the top, without the
    /// bob), which the trail is centred on.
    static let bodyRows = 1...8

    static let stripeCount = 6

    static let palette: [Character: (CGFloat, CGFloat, CGFloat)] = [
        "W": (0.96, 0.96, 0.98),
        "S": (0.62, 0.64, 0.72),
        "P": (1.00, 0.55, 0.70),
        "K": (0.08, 0.08, 0.11),
        "D": (0.30, 0.31, 0.37),
        "G": (0.50, 0.51, 0.58),
    ]

    // A keyboard eight rows tall: a charcoal frame, three rows where the
    // black keys hang, three rows of white keys with gaps under them.
    static let body = [
        "DDDDDDDDDDDDD",
        "DWKKWKKWWKKWD",
        "DWKKWKKWWKKWD",
        "DWKKWKKWWKKWD",
        "DWWSWWSWWSWWD",
        "DWWSWWSWWSWWD",
        "DWWSWWSWWSWWD",
        "DDDDDDDDDDDDD",
    ]

    // A grey head, dark against the white keys, mostly over the keyboard
    // with about a third of it out in front. The mouth is drawn finer, see
    // `mouth`.
    static let head = [
        "G.....G",
        "GG...GG",
        "GGGGGGG",
        "GKGGGKG",
        "PGGGGGP",
        ".GGGGG.",
    ]

    static let headOrigin = (row: 3, column: 11)

    /// A cat's "ω" in half pixels (one point each), filling the middle three
    /// columns of the head's cheek row.
    private static let mouth = [
        "X.XX.X",
        ".X..X.",
    ]

    static let mouthOrigin = (row: headOrigin.row + 4, column: headOrigin.column + 2)

    /// The keyboard's visible corners as (row, column, left, top); the front
    /// bottom one is behind the head.
    private static let bodyCorners = [
        (1, bodyLeftColumn, true, true),
        (1, bodyLeftColumn + 12, false, true),
        (8, bodyLeftColumn, true, false),
    ]

    /// Paws step back and forth under the keyboard; the tail swings.
    /// Hind paws at the back corner of the keyboard, fore paws under the head.
    private static let pawsForward = [3, 5, 12, 14]

    private static let pawsBack = [4, 6, 13, 15]

    /// The tail, two pixels thick, leaves the keyboard's back edge and
    /// swings up, level and down.
    private static let tailUp = [(4, 2), (5, 2), (3, 1), (4, 1), (2, 0), (3, 0)]

    private static let tailLevel = [(4, 2), (5, 2), (4, 1), (5, 1), (4, 0), (5, 0)]

    private static let tailDown = [(4, 2), (5, 2), (5, 1), (6, 1), (6, 0), (7, 0)]

    private typealias Grid = [[Character]]

    private static func emptyGrid() -> Grid {
        Grid(repeating: [Character](repeating: ".", count: width), count: height)
    }

    private static func stamp(_ rows: [String], into grid: inout Grid, row: Int, column: Int) {
        for (r, line) in rows.enumerated() {
            for (c, character) in line.enumerated() where character != "." {
                grid[row + r][column + c] = character
            }
        }
    }

    private static func frame(paws: [Int], tail: [(Int, Int)], bob: Bool) -> [String] {
        var grid = emptyGrid()
        stamp(body, into: &grid, row: 1, column: bodyLeftColumn)
        stamp(head, into: &grid, row: headOrigin.row, column: headOrigin.column)
        for column in paws { grid[9][column] = "G" }
        for (row, column) in tail { grid[row][column] = "G" }
        // Bobbing up a pixel while the paws pass under the body.
        if bob { grid = Array(grid.dropFirst()) + [[Character](repeating: ".", count: width)] }
        return grid.map { String($0) }
    }

    private static let bobs = [false, true, false, true]

    static let frames: [[String]] = [
        frame(paws: pawsForward, tail: tailUp, bob: bobs[0]),
        frame(paws: pawsBack, tail: tailLevel, bob: bobs[1]),
        frame(paws: pawsForward, tail: tailDown, bob: bobs[2]),
        frame(paws: pawsBack, tail: tailLevel, bob: bobs[3]),
    ]

    static let rainbow: [(CGFloat, CGFloat, CGFloat)] = [
        (1.00, 0.27, 0.30), (1.00, 0.60, 0.20), (1.00, 0.90, 0.25),
        (0.35, 0.88, 0.40), (0.30, 0.65, 1.00), (0.62, 0.42, 0.98),
    ]

    /// The cat's running frames as images, one device pixel per `scale`.
    static func catImages(scale: CGFloat) -> [CGImage] {
        frames.enumerated().compactMap { index, rows in
            catImage(
                rows: rows, scale: scale, lift: bobs[index] ? 1 : 0, corners: bodyCorners,
                fine: [(mouth, mouthOrigin.row, mouthOrigin.column)]
            )
        }
    }

    /// `lift` is the rows the frame was bobbed up by; `corners` are bevelled
    /// and each of `fine` is drawn in half pixels from the top left of a
    /// cell, both counted in the frame without the bob. In fine patterns,
    /// "X" draws a dark detail, "-" clears a half pixel and other letters
    /// use the palette.
    private static func catImage(
        rows: [String], scale: CGFloat, lift: Int, corners: [(Int, Int, Bool, Bool)],
        fine: [(pattern: [String], row: Int, column: Int)]
    ) -> CGImage? {
        image(rows: rows, scale: scale, color: { palette[$0] }) { context, side in
            // Device-pixel cell origin; Core Graphics counts rows from the bottom.
            func origin(_ row: Int, _ column: Int) -> (x: Int, y: Int) {
                (column * side, (rows.count - 1 - (row - lift)) * side)
            }
            // A slight bevel: a small step of device pixels off each corner.
            let cut = max(1, side / 2)
            for (row, column, left, top) in corners {
                let cell = origin(row, column)
                for dx in 0..<cut {
                    for dy in 0..<(cut - dx) {
                        let x = left ? cell.x + dx : cell.x + side - 1 - dx
                        let y = top ? cell.y + side - 1 - dy : cell.y + dy
                        context.clear(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
            let half = max(1, side / 2)
            for (pattern, row, column) in fine {
                let cell = origin(row, column)
                for (r, line) in pattern.enumerated() {
                    for (c, character) in line.enumerated() where character != "." {
                        let y = cell.y + side - (r + 1) * half
                        let rect = CGRect(x: cell.x + c * half, y: y, width: half, height: half)
                        if character == "-" {
                            context.clear(rect)
                        } else if let rgb = palette[character == "X" ? "K" : character] {
                            context.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
                            context.fill(rect)
                        }
                    }
                }
            }
        }
    }

    /// One trail column: the six rainbow stripes, one pixel each.
    static func stripeImage(scale: CGFloat) -> CGImage? {
        let rows = (0..<rainbow.count).map { String(Character("\($0)")) }
        return image(rows: rows, scale: scale) { character in
            character.wholeNumberValue.map { rainbow[$0] }
        }
    }

    static func outlinedImage(rows: [String], scale: CGFloat, color: (CGFloat, CGFloat, CGFloat)) -> CGImage? {
        let side = max(1, Int(scale.rounded()))
        let outline = max(1, Int((scale / 2).rounded()))
        let columns = rows.map(\.count).max() ?? 0
        let width = columns * side + 2 * outline
        let height = rows.count * side + 2 * outline
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        func cell(_ row: Int, _ column: Int) -> CGRect {
            CGRect(x: outline + column * side, y: outline + (rows.count - 1 - row) * side, width: side, height: side)
        }
        let filled = rows.enumerated().flatMap { row, line in
            line.enumerated().compactMap { column, character in character == "X" ? (row, column) : nil }
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.9)
        for (row, column) in filled {
            context.fill(cell(row, column).insetBy(dx: -CGFloat(outline), dy: -CGFloat(outline)))
        }
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        for (row, column) in filled { context.fill(cell(row, column)) }
        return context.makeImage()
    }

    /// `details` draws on top, given the context and the device pixels per
    /// sprite pixel.
    static func image(
        rows: [String], scale: CGFloat, color: (Character) -> (CGFloat, CGFloat, CGFloat)?,
        details: ((CGContext, Int) -> Void)? = nil
    ) -> CGImage? {
        let side = max(1, Int((pixel * scale).rounded()))
        let columns = rows.map(\.count).max() ?? 0
        guard let context = CGContext(
            data: nil, width: columns * side, height: rows.count * side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        for (rowIndex, row) in rows.enumerated() {
            for (column, character) in row.enumerated() {
                guard let rgb = color(character) else { continue }
                context.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
                // Core Graphics counts rows from the bottom.
                let y = (rows.count - 1 - rowIndex) * side
                context.fill(CGRect(x: column * side, y: y, width: side, height: side))
            }
        }
        details?(context, side)
        return context.makeImage()
    }
}
