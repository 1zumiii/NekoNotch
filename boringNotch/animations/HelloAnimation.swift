//
//  HelloAnimation.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/08/24.
//

import SwiftUI

/// The rainbow cat's head, drawn as one stroke the way the first-launch
/// greeting writes "hello": the outline in pixel steps (two pointed ears, a
/// square face), then the eyes, then the ω mouth. Coordinates are in the
/// head's own pixels, 7 wide and 6 tall, as in PixelCatSprites.
struct HelloShape: Shape {
    private static let outline: [CGPoint] = [
        (1, 6), (1, 5), (0, 5), (0, 0), (1, 0), (1, 1), (2, 1), (2, 2), (5, 2),
        (5, 1), (6, 1), (6, 0), (7, 0), (7, 5), (6, 5), (6, 6), (1, 6),
    ].map { CGPoint(x: $0.0, y: $0.1) }
    private static let eyes: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 1.5, y: 3.2), CGPoint(x: 1.5, y: 3.8)),
        (CGPoint(x: 5.5, y: 3.2), CGPoint(x: 5.5, y: 3.8)),
    ]
    private static let mouth: [CGPoint] = [
        (2.25, 4.3), (2.75, 4.8), (3.5, 4.3), (4.25, 4.8), (4.75, 4.3),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    func path(in rect: CGRect) -> Path {
        // Fit the 7 × 6 head in the rect, centred, with room for the stroke.
        let unit = min(rect.width / 7, rect.height / 6) * 0.86
        let origin = CGPoint(x: rect.midX - 3.5 * unit, y: rect.midY - 3 * unit)
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * unit, y: origin.y + p.y * unit) }
        var path = Path()
        path.addLines(Self.outline.map(point))
        for (from, to) in Self.eyes {
            path.move(to: point(from))
            path.addLine(to: point(to))
        }
        path.move(to: point(Self.mouth[0]))
        path.addLines(Self.mouth.map(point))
        return path
    }
}

extension ShapeStyle where Self == AngularGradient {
    static var hello: some ShapeStyle {
        LinearGradient(
            stops: [
                .init(color: .blue, location: 0.0),
                .init(color: .purple, location: 0.2),
                .init(color: .red, location: 0.4),
                .init(color: .mint, location: 0.5),
                .init(color: .indigo, location: 0.7),
                .init(color: .pink, location: 0.9),
                .init(color: .blue, location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

struct GlowingSnake<
    Content: Shape,
    Fill: ShapeStyle
>: View, @MainActor Animatable {
    var progress: Double
    var delay: Double = 1.0
    var fill: Fill
    var lineWidth = 4.0
    var blurRadius = 8.0

    @ViewBuilder var shape: Content

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        shape
            .trim(
                from: {
                    if progress > 1 - delay {
                        2 * progress - 1.0
                    } else if progress > delay {
                        progress - delay
                    } else {
                        .zero
                    }
                }(),
                to: progress
            )
            .glow(
                fill: fill,
                lineWidth: lineWidth,
                blurRadius: blurRadius
            )
    }
}

struct HelloAnimation: View {
    @State private var progress: Double = 0.0

    var onFinish: () -> Void

    var body: some View {
        GlowingSnake(
            progress: progress,
            fill: .hello,
            lineWidth: 8,
            blurRadius: 8.0,
            shape: { HelloShape() }
        )
        .task {
            // Wait for the "opening" animation (notch expansion) to complete before starting the snake
            try? await Task.sleep(for: .seconds(0.6))

            withAnimation(
                .easeInOut(duration: 4.0)
            ) {
                progress = 1.0
            }

            // Wait for the animation to complete
            try? await Task.sleep(for: .seconds(4.0))

            onFinish()
        }
    }
}

extension View where Self: Shape {
    func glow(
        fill: some ShapeStyle,
        lineWidth: Double,
        blurRadius: Double = 8.0,
        lineCap: CGLineCap = .round
    ) -> some View {
        self
            .stroke(style: StrokeStyle(lineWidth: lineWidth / 2, lineCap: lineCap))
            .fill(fill)
            .overlay {
                self
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: lineCap))
                    .fill(fill)
                    .blur(radius: blurRadius)
            }
            .overlay {
                self
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: lineCap))
                    .fill(fill)
                    .blur(radius: blurRadius / 2)
            }
    }
}

#Preview {
    HelloAnimation(onFinish: {})
        .frame(width: 300, height: 100)
}
