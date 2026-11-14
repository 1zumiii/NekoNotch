//
//  PixelCatSprites+Sky.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The sky behind the cat: stars in three depths and their tints, warp
//  streaks, and the tails stars carry as they brake out of warp.
//
import CoreGraphics
import Foundation

extension PixelCatSprites {
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

    /// The tail a star still carries as it brakes out of warp, in each of the
    /// stars' tints: bright where it leaves the star (on the left) and
    /// fading out, like a streak's. A strip `length` sprite pixels long and
    /// one device pixel high, to be stretched to the tail's size.
    static func tailImages(scale: CGFloat, length: Int) -> [CGImage] {
        let length = max(1, Int((CGFloat(length) * pixel * scale).rounded()))
        return starTints.compactMap { tint in
            guard let context = CGContext(
                data: nil, width: length, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            for x in 0..<length {
                // Squared, as the streaks', so the light stays near the star.
                let fade = 1 - CGFloat(x) / CGFloat(length)
                context.setFillColor(red: tint.0, green: tint.1, blue: tint.2, alpha: fade * fade)
                context.fill(CGRect(x: x, y: 0, width: 1, height: 1))
            }
            return context.makeImage()
        }
    }
}
