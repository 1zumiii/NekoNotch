//
//  NotchShape.swift
//  boringNotch
//
// Created by Kai Azim on 2023-08-24.
// Original source: https://github.com/MrKai77/DynamicNotchKit
// Modified by Alexander on 2025-05-18.

import SwiftUI

struct NotchShape: Shape {
    private var topCornerRadius: CGFloat
    private var bottomCornerRadius: CGFloat

    init(
        topCornerRadius: CGFloat? = nil,
        bottomCornerRadius: CGFloat? = nil
    ) {
        self.topCornerRadius = topCornerRadius ?? 6
        self.bottomCornerRadius = bottomCornerRadius ?? 14
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            .init(
                topCornerRadius,
                bottomCornerRadius
            )
        }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.minY + topCornerRadius
            ),
            control: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.minY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.maxY - bottomCornerRadius
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + topCornerRadius + bottomCornerRadius,
                y: rect.maxY
            ),
            control: CGPoint(
                x: rect.minX + topCornerRadius,
                y: rect.maxY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.maxX - topCornerRadius - bottomCornerRadius,
                y: rect.maxY
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.maxY - bottomCornerRadius
            ),
            control: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.maxY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.minY + topCornerRadius
            )
        )

        path.addQuadCurve(
            to: CGPoint(
                x: rect.maxX,
                y: rect.minY
            ),
            control: CGPoint(
                x: rect.maxX - topCornerRadius,
                y: rect.minY
            )
        )

        path.addLine(
            to: CGPoint(
                x: rect.minX,
                y: rect.minY
            )
        )

        return path
    }
}

extension NotchShape {
    /// Just the side and bottom edges, without the flared corners at the top.
    var sidesOnly: NotchSidesShape {
        NotchSidesShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
    }
}

struct NotchSidesShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius))
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        return path
    }
}

/// The bottom edge only: the two bottom corners and the flat run between them.
struct NotchBottomShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        return path
    }
}

extension NotchShape {
    var bottomOnly: NotchBottomShape {
        NotchBottomShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
    }
}

/// A few seconds of the battery line in a state the battery is not in, so the
/// look can be checked from the settings without waiting for it.
@MainActor
final class BatteryEdgeLinePreview: ObservableObject {
    static let shared = BatteryEdgeLinePreview()

    enum Mode {
        case low, charging

        var level: Double { self == .low ? 0.12 : 0.6 }
        var charging: Bool { self == .charging }
    }

    @Published private(set) var mode: Mode?
    private var endTask: Task<Void, Never>?
    private static let duration: TimeInterval = 8

    func show(_ mode: Mode) {
        endTask?.cancel()
        self.mode = mode
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            guard !Task.isCancelled else { return }
            self?.mode = nil
        }
    }
}

/// The charge as a thin line just under the notch, filling from the left like
/// a progress bar. It sits outside the notch's outline on purpose: the notch is
/// a hole in the display, so a line drawn inside the shape would be hidden
/// wherever the shape lies over the hardware notch. It follows the bottom
/// corners and fades out as they curve up, so it never ends in a hard cut and
/// does not run up the sides.
struct BatteryEdgeLine: View {
    let outline: NotchShape
    let shape: NotchBottomShape
    /// 0...1
    let level: Double
    let charging: Bool

    /// Stroked on the outline's edge; the inner half is cut away, so this
    /// is twice the visible thickness.
    fileprivate static let strokeWidth: CGFloat = 3.2
    fileprivate static let margin: CGFloat = 8
    /// A dark rim outside the line, so it reads on light windows too: there
    /// it looks like the notch's own edge with the line set into it, and on
    /// dark ones it disappears.
    private static let rimWidth: CGFloat = 1
    private static let rimOpacity = 0.85

    private var isLow: Bool { !charging && level <= 0.2 }

    private var color: Color {
        if charging { return Color(red: 0.30, green: 0.85, blue: 0.40) }
        if isLow { return Color(red: 1.0, green: 0.33, blue: 0.30) }
        return .white.opacity(0.9)
    }

    /// Where the horizontal fade starts and ends, as fractions of a mask that
    /// reaches `margin * 2` past each side: fully clear on the lines that
    /// extend the notch's sides, so the ends never reach past them, and solid
    /// once the line is most of the way round each corner.
    static func fadeLocations(width: CGFloat, edge: CGFloat, radius: CGFloat) -> [CGFloat] {
        let totalWidth = width + margin * 4
        return [
            max(0, (edge + margin * 2) / totalWidth),
            min(1, (edge + radius * 0.75 + margin * 2) / totalWidth),
            max(0, (width - edge - radius * 0.75 + margin * 2) / totalWidth),
            min(1, (width - edge + margin * 2) / totalWidth)
        ]
    }

    var body: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height, 1)
            let radius = max(shape.bottomCornerRadius, 1)
            let total = height + Self.margin * 2
            let width = max(proxy.size.width, 1)
            let totalWidth = width + Self.margin * 4
            let edge = shape.topCornerRadius
            let fill = shape.trim(from: 0, to: min(max(level, 0), 1))
            ZStack {
                shape.stroke(
                    Color.black.opacity(Self.rimOpacity),
                    style: StrokeStyle(lineWidth: Self.strokeWidth + Self.rimWidth * 2, lineCap: .round)
                )
                shape.stroke(Color.white.opacity(0.13), style: StrokeStyle(lineWidth: Self.strokeWidth, lineCap: .round))
                // A red glow under a low charge, so it is noticed.
                if isLow {
                    fill.stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: Self.strokeWidth * 2.2, lineCap: .round))
                        .blur(radius: 2.5)
                }
                fill.stroke(color, style: StrokeStyle(lineWidth: Self.strokeWidth, lineCap: .round))
            }
            // Only the part outside the notch: cut the notch's own area out.
            .mask(
                ZStack {
                    Rectangle().fill(Color.black).padding(-Self.margin * 2)
                    outline.fill(Color.black).blendMode(.destinationOut)
                }
                .compositingGroup()
            )
            // Fade by horizontal position, see fadeLocations.
            .mask {
                let locations = Self.fadeLocations(width: width, edge: edge, radius: radius)
                Rectangle()
                    .fill(LinearGradient(
                        stops: [
                            .init(color: .clear, location: locations[0]),
                            .init(color: .black, location: locations[1]),
                            .init(color: .black, location: locations[2]),
                            .init(color: .clear, location: locations[3])
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: totalWidth, height: total)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: level)
        .overlay {
            if charging {
                ChargingPulse(outline: outline, shape: shape, level: min(max(level, 0), 1))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The charging pulse over the battery line, played by Core Animation.
/// Charging lasts hours, and any SwiftUI animation would lay out and commit
/// the whole notch window in this process on every frame of it; here the
/// window server runs the loop and the app does nothing between level changes.
private struct ChargingPulse: NSViewRepresentable {
    let outline: NotchShape
    let shape: NotchBottomShape
    /// 0...1
    let level: Double

    func makeNSView(context: Context) -> ChargingPulseView { ChargingPulseView() }

    func updateNSView(_ view: ChargingPulseView, context: Context) {
        view.update(outline: outline, shape: shape, level: level)
    }
}

private final class ChargingPulseView: NSView {
    /// One pulse runs left to right in `travel`, then the line rests until
    /// the period is over.
    private static let period: CFTimeInterval = 2.2
    private static let travel: CFTimeInterval = 1.4
    /// Length of the tail, as a fraction of the whole line.
    private static let length: Double = 0.22
    /// The tail is stacked segments that get brighter toward the head, so it
    /// fades out instead of ending in a cut.
    private static let segmentFractions: [Double] = [1.0, 0.6, 0.3]
    private static let samples = 60
    private static let animationKey = "pulse"

    /// The same two masks as the line underneath: the fade by horizontal
    /// position outside, the notch's own area cut out inside.
    private let fadeHost = CALayer()
    private let fadeMask = CAGradientLayer()
    private let cutHost = CALayer()
    private let cutMask = CAShapeLayer()
    private let segments: [CAShapeLayer]

    private var outline: NotchShape?
    private var shape: NotchBottomShape?
    private var level: Double?

    override var isFlipped: Bool { true }

    init() {
        segments = Self.segmentFractions.map { _ in CAShapeLayer() }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeHost.mask = fadeMask
        cutMask.fillRule = .evenOdd
        cutMask.fillColor = NSColor.black.cgColor
        cutHost.mask = cutMask
        for segment in segments {
            segment.fillColor = nil
            segment.strokeColor = NSColor.white.withAlphaComponent(0.45).cgColor
            segment.lineWidth = BatteryEdgeLine.strokeWidth
            segment.lineCap = .round
            segment.opacity = 0
            cutHost.addSublayer(segment)
        }
        fadeHost.addSublayer(cutHost)
        layer?.addSublayer(fadeHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(outline: NotchShape, shape: NotchBottomShape, level: Double) {
        self.outline = outline
        self.shape = shape
        needsLayout = true
        if level != self.level {
            self.level = level
            startAnimation()
        }
    }

    /// The notch's width changes under live activities: only the paths
    /// follow, the running loop is left alone.
    override func layout() {
        super.layout()
        guard let outline, let shape else { return }
        let bounds = self.bounds
        let margin = BatteryEdgeLine.margin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeHost.frame = bounds
        cutHost.frame = bounds
        fadeMask.frame = CGRect(
            x: -margin * 2, y: -margin,
            width: bounds.width + margin * 4, height: bounds.height + margin * 2
        )
        fadeMask.locations = BatteryEdgeLine.fadeLocations(
            width: max(bounds.width, 1), edge: shape.topCornerRadius, radius: max(shape.bottomCornerRadius, 1)
        ).map { NSNumber(value: Double($0)) }
        let cut = CGMutablePath()
        cut.addRect(bounds.insetBy(dx: -margin * 2, dy: -margin * 2))
        cut.addPath(outline.path(in: bounds).cgPath)
        cutMask.frame = bounds
        cutMask.path = cut
        let line = shape.path(in: bounds).cgPath
        for segment in segments {
            segment.frame = bounds
            segment.path = line
        }
        CATransaction.commit()
    }

    /// One loop per segment, sampled from the same eased head position the
    /// pulse always had. Started in phase with the clock, so a level change
    /// does not make the pulse jump back to the start.
    private func startAnimation() {
        guard let level else { return }
        let restStart = Self.travel / Self.period
        let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
        for (segment, fraction) in zip(segments, Self.segmentFractions) {
            var keyTimes: [NSNumber] = []
            var starts: [Double] = []
            var ends: [Double] = []
            var opacities: [Double] = []
            for index in 0...Self.samples {
                let progress = Double(index) / Double(Self.samples)
                let eased = progress * progress * (3 - 2 * progress)
                let head = eased * (level + Self.length)
                let end = min(head, level)
                let start = min(max(head - Self.length * fraction, 0), end)
                keyTimes.append(NSNumber(value: progress * restStart))
                starts.append(start)
                ends.append(end)
                opacities.append(end - start > 0.0005 ? 1 : 0)
            }
            // At rest until the period ends.
            keyTimes.append(1)
            starts.append(level)
            ends.append(level)
            opacities.append(0)

            func keyframes(_ keyPath: String, _ values: [Double]) -> CAKeyframeAnimation {
                let animation = CAKeyframeAnimation(keyPath: keyPath)
                animation.values = values
                animation.keyTimes = keyTimes
                animation.duration = Self.period
                return animation
            }
            let group = CAAnimationGroup()
            group.animations = [
                keyframes("strokeStart", starts),
                keyframes("strokeEnd", ends),
                keyframes("opacity", opacities)
            ]
            group.duration = Self.period
            group.repeatCount = .infinity
            group.beginTime = CACurrentMediaTime() - phase
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
            segment.add(group, forKey: Self.animationKey)
        }
    }
}

#Preview {
    NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
        .frame(width: 200, height: 32)
        .padding(10)
}
