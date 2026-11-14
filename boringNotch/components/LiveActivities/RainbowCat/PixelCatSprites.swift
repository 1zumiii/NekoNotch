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

    private static let palette: [Character: (CGFloat, CGFloat, CGFloat)] = [
        "W": (0.96, 0.96, 0.98),
        "S": (0.62, 0.64, 0.72),
        "P": (1.00, 0.55, 0.70),
        "K": (0.08, 0.08, 0.11),
        "D": (0.30, 0.31, 0.37),
        "G": (0.50, 0.51, 0.58),
    ]

    // A keyboard eight rows tall: a charcoal frame, three rows where the
    // black keys hang, three rows of white keys with gaps under them.
    private static let body = [
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
    private static let head = [
        "G.....G",
        "GG...GG",
        "GGGGGGG",
        "GKGGGKG",
        "PGGGGGP",
        ".GGGGG.",
    ]
    private static let headOrigin = (row: 3, column: 11)
    /// A cat's "ω" in half pixels (one point each), filling the middle three
    /// columns of the head's cheek row.
    private static let mouth = [
        "X.XX.X",
        ".X..X.",
    ]
    private static let mouthOrigin = (row: headOrigin.row + 4, column: headOrigin.column + 2)
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

    private static func frame(paws: [Int], tail: [(Int, Int)], bob: Bool) -> [String] {
        var grid = [[Character]](repeating: [Character](repeating: ".", count: width), count: height)
        func stamp(_ rows: [String], row: Int, column: Int) {
            for (r, line) in rows.enumerated() {
                for (c, character) in line.enumerated() where character != "." {
                    grid[row + r][column + c] = character
                }
            }
        }
        stamp(body, row: 1, column: bodyLeftColumn)
        stamp(head, row: headOrigin.row, column: headOrigin.column)
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

    /// The cat's frames as images, one device pixel per `scale`.
    static func catImages(scale: CGFloat) -> [CGImage] {
        frames.enumerated().compactMap { index, rows in
            let lift = bobs[index] ? 1 : 0
            return image(rows: rows, scale: scale, color: { palette[$0] }) { context, side in
                // Device-pixel cell origin; Core Graphics counts rows from the bottom.
                func origin(_ row: Int, _ column: Int) -> (x: Int, y: Int) {
                    (column * side, (rows.count - 1 - (row - lift)) * side)
                }
                // A slight bevel: a small step of device pixels off each corner.
                let cut = max(1, side / 2)
                for (row, column, left, top) in bodyCorners {
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
                let rgb = palette["K"]!
                context.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
                let cell = origin(mouthOrigin.row, mouthOrigin.column)
                for (r, line) in mouth.enumerated() {
                    for (c, character) in line.enumerated() where character == "X" {
                        let y = cell.y + side - (r + 1) * half
                        context.fill(CGRect(x: cell.x + c * half, y: y, width: half, height: half))
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

    /// Stars drifting past in the background, far ones (a dot) and near
    /// ones (a plus), each in white and pale yellow.
    /// White, pale yellow and pale blue, the colours stars come in.
    static let starTints: [(CGFloat, CGFloat, CGFloat)] = [(1, 1, 1), (1.0, 0.92, 0.55), (0.72, 0.84, 1.0)]

    static func starImages(scale: CGFloat, near: Bool) -> [CGImage] {
        let shape = near ? [".X.", "XXX", ".X."] : ["X"]
        return starTints.compactMap { tint in image(rows: shape, scale: scale) { $0 == "X" ? tint : nil } }
    }

    /// The furthest stars: a single point, half a sprite pixel, in each tint.
    static func dustImages(scale: CGFloat) -> [CGImage] {
        let side = max(1, Int(scale.rounded()))
        return starTints.compactMap { tint in
            guard let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(red: tint.0, green: tint.1, blue: tint.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            return context.makeImage()
        }
    }

    /// Streaks of light for warp speed, in the stars' white and pale yellow:
    /// a bright head on the left (they fly left) and a tail fading out
    /// behind it. Far ones are thin and shorter, near ones thick and longer. The
    /// image is twice the streak's length with the head in the middle, so a
    /// streak born out of sight has its whole tail out of sight too.
    static func streakImages(scale: CGFloat, near: Bool) -> [CGImage] {
        let length = Int(((near ? 48 : 28) * scale).rounded())
        let thickness = max(1, Int(((near ? 2 : 1) * scale).rounded()))
        let tints: [(CGFloat, CGFloat, CGFloat)] = [(1, 1, 1), (1.0, 0.92, 0.55)]
        return tints.compactMap { tint in
            guard let context = CGContext(
                data: nil, width: 2 * length, height: thickness, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            for x in 0..<length {
                // Squared, so the light stays near the head.
                let fade = 1 - CGFloat(x) / CGFloat(length)
                let alpha = fade * fade
                context.setFillColor(red: tint.0, green: tint.1, blue: tint.2, alpha: alpha)
                context.fill(CGRect(x: length + x, y: 0, width: 1, height: thickness))
            }
            return context.makeImage()
        }
    }

    /// Music notes in each rainbow colour, single and beamed in turn: one
    /// point a pixel with a half-point white outline (two device pixels and
    /// one, on Retina), so they stand out against the dark notch.
    static func noteImages(scale: CGFloat) -> [CGImage] {
        rainbow.enumerated().compactMap { index, color in
            outlinedImage(rows: notes[index % notes.count], scale: scale, color: color)
        }
    }

    private static func outlinedImage(rows: [String], scale: CGFloat, color: (CGFloat, CGFloat, CGFloat)) -> CGImage? {
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
    private static func image(
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
