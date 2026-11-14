//
//  main.swift
//  cat-sprite-preview
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Draws the rainbow cat's frames side by side, each pixel enlarged, so a
//  pose can be checked without building the app. Built and run by
//  scripts/preview-cat-sprites.sh.
//
import AppKit

let arguments = CommandLine.arguments
let output = arguments.count > 1 ? arguments[1] : "build/cat-sprites.png"
let zoom = arguments.count > 2 ? Int(arguments[2]) ?? 8 : 8
let scale: CGFloat = 2

let frames = PixelCatSprites.catImages(scale: scale) + PixelCatSprites.brakeImages(scale: scale)
guard let first = frames.first else { fatalError("no frames") }
let gap = 6 * zoom
let cell = (width: first.width * zoom, height: first.height * zoom)
let width = frames.count * cell.width + (frames.count + 1) * gap
let height = cell.height + 2 * gap

guard let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }
context.setFillColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1)
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.interpolationQuality = .none
for (index, frame) in frames.enumerated() {
    let rect = CGRect(x: gap + index * (cell.width + gap), y: gap, width: cell.width, height: cell.height)
    context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    context.fill(rect)
    context.draw(frame, in: rect)
}
guard let image = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("no image") }
try png.write(to: URL(fileURLWithPath: output))
print("Running frames 1-4, then bracing and braced: \(output)")
