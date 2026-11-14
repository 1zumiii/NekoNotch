//
//  NotificationLiveActivity.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct NotificationSourceIcon: View {
    let bundleID: String?
    let size: CGFloat
    /// A small dot at the bottom right that marks the icon as a notification.
    var showsBadge = false

    var body: some View {
        icon
            .overlay(alignment: .bottomTrailing) {
                if showsBadge {
                    Circle()
                        .fill(Color.effectiveAccent)
                        .frame(width: size * 0.32, height: size * 0.32)
                        .overlay(Circle().stroke(.black, lineWidth: 1.5))
                        .offset(x: size * 0.08, y: size * 0.08)
                }
            }
    }

    @ViewBuilder
    private var icon: some View {
        if let agent = SystemNotificationAgents.info(bundleID: bundleID) {
            Image(systemName: agent.symbol)
                .font(.system(size: size * 0.55))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: size, height: size)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.2))
        } else if let bundleID {
            appIcon(for: bundleID)
                .resizable().scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            Image(systemName: "bell")
                .font(.system(size: size * 0.55))
                .frame(width: size, height: size)
        }
    }
}

/// A slowly turning rainbow outline around the notch, for high-priority
/// notifications. Only on screen while one is.
private let priorityGlowColors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red]

/// Played by Core Animation: a time-sensitive notification stays on screen
/// for up to a minute, and a SwiftUI loop would lay out and commit the whole
/// notch window in this process on every frame of it.
struct PriorityGlowBorder<S: Shape>: NSViewRepresentable {
    let shape: S

    func makeNSView(context: Context) -> PriorityGlowView { PriorityGlowView() }

    func updateNSView(_ view: PriorityGlowView, context: Context) {
        view.pathProvider = { shape.path(in: $0).cgPath }
    }
}

final class PriorityGlowView: NSView {
    private static let period: CFTimeInterval = 4
    private static let lineWidth: CGFloat = 2
    /// Widening, fading strokes that stand in for a blur. A Core Image blur
    /// would need the layer tree rendered in this process.
    private static let glowStrokes: [(width: CGFloat, opacity: Float)] = [(5, 0.45), (9, 0.22), (14, 0.1)]
    private static let animationKey = "turn"

    private let glowGradient = CAGradientLayer()
    private let lineGradient = CAGradientLayer()
    private let glowMask = CALayer()
    private let glowMaskStrokes: [CAShapeLayer]
    private let lineMask = CAShapeLayer()
    private let glowHost = CALayer()
    private let lineHost = CALayer()

    var pathProvider: ((CGRect) -> CGPath)? {
        didSet { needsLayout = true }
    }

    override var isFlipped: Bool { true }

    init() {
        glowMaskStrokes = Self.glowStrokes.map { _ in CAShapeLayer() }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        let colors = priorityGlowColors.map { NSColor($0).cgColor }
        for gradient in [glowGradient, lineGradient] {
            gradient.type = .conic
            gradient.colors = colors
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
        }
        for (stroke, style) in zip(glowMaskStrokes, Self.glowStrokes) {
            configure(stroke, width: style.width)
            stroke.opacity = style.opacity
            glowMask.addSublayer(stroke)
        }
        configure(lineMask, width: Self.lineWidth)

        glowHost.addSublayer(glowGradient)
        glowHost.mask = glowMask
        glowHost.opacity = 0.7
        lineHost.addSublayer(lineGradient)
        lineHost.mask = lineMask
        layer?.addSublayer(glowHost)
        layer?.addSublayer(lineHost)
        startAnimation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func configure(_ stroke: CAShapeLayer, width: CGFloat) {
        stroke.fillColor = nil
        stroke.strokeColor = NSColor.black.cgColor
        stroke.lineWidth = width
        stroke.lineCap = .round
    }

    /// The notch's size changes under it: only the paths and frames follow,
    /// the running turn is left alone.
    override func layout() {
        super.layout()
        guard let pathProvider else { return }
        let bounds = self.bounds
        let path = pathProvider(bounds)
        // Square and as wide as the diagonal, so the turning gradient
        // always covers the outline.
        let side = hypot(bounds.width, bounds.height) + 32
        let square = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for host in [glowHost, lineHost] {
            host.frame = bounds
        }
        for gradient in [glowGradient, lineGradient] {
            gradient.bounds = CGRect(origin: .zero, size: square.size)
            gradient.position = CGPoint(x: square.midX, y: square.midY)
        }
        glowMask.frame = bounds
        for stroke in glowMaskStrokes + [lineMask] {
            stroke.frame = bounds
            stroke.path = path
        }
        CATransaction.commit()
    }

    private func startAnimation() {
        for gradient in [glowGradient, lineGradient] {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = Double.pi * 2
            turn.duration = Self.period
            turn.repeatCount = .infinity
            turn.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
            gradient.add(turn, forKey: Self.animationKey)
        }
    }
}

struct NotificationLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    let notification: SystemNotification
    /// Just the app's icon on the left, for an icon-only app.
    var iconOnly = false

    @State private var ringScale: CGFloat = 1
    @State private var ringOpacity = 0.0

    private var itemSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    /// Without the cat: the icon, the middle and a dot. Beside the cat the
    /// icon goes in the cat's row instead (see `ContentView.ClosedCatRow`).
    var body: some View {
        HStack {
            NotificationSourceIcon(
                bundleID: notification.bundleID,
                size: itemSize,
                showsBadge: iconOnly
            )

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            dot
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .onAppear { pulse() }
        .onChange(of: notification.id) { _, _ in pulse() }
    }

    private var dot: some View {
            ZStack {
                if !iconOnly {
                    Circle()
                        .stroke(Color.effectiveAccent, lineWidth: 1.5)
                        .scaleEffect(ringScale)
                        .opacity(ringOpacity)
                    Circle()
                        .fill(Color.effectiveAccent)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: itemSize, height: itemSize)
    }

    private func pulse() {
        ringScale = 1
        ringOpacity = 0.8
        withAnimation(.easeOut(duration: 0.6)) {
            ringScale = 1.8
            ringOpacity = 0
        }
    }
}

/// One line of a notification's text under the closed notch. Text that fits
/// stays for the icon-only time; longer text waits, runs to its end at a
/// steady pace, waits again, and then the row asks to be taken away.
struct NotificationTickerRow: View {
    let notification: SystemNotification
    let width: CGFloat
    let onFinish: () -> Void

    @State private var offset: CGFloat = 0

    private static let fontSize: CGFloat = 11
    private static let pointsPerSecond: CGFloat = 45
    private static let hold: Double = 1.2
    /// Room left after the last character once the text has run to its
    /// end, so it doesn't stop flush against the edge of the notch.
    private static let endGap: CGFloat = 12
    /// Where long text starts, in from the row's left edge: the row is as
    /// wide as the notch, whose rounded corner would cut the first character.
    /// It still runs out of sight at the left and comes in at the right edge.
    private static let leadInset: CGFloat = 10

    static func text(for notification: SystemNotification) -> String {
        [notification.title, notification.subtitle, notification.body]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "  ·  ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private var text: String { Self.text(for: notification) }

    private var textWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: Self.fontSize, weight: .medium)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    var body: some View {
        let scrolls = textWidth > width - Self.leadInset - Self.endGap
        // From leadInset to where the last character stops endGap short of
        // the right edge.
        let start = Self.leadInset
        let end = width - textWidth - Self.endGap
        Text(text)
            .font(.system(size: Self.fontSize, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: offset)
            .frame(width: width, alignment: scrolls ? .leading : .center)
            .clipped()
            .padding(.bottom, 5)
            .allowsHitTesting(false)
            .task(id: notification.id) {
                offset = scrolls ? start : 0
                if scrolls {
                    let run = Double((start - end) / Self.pointsPerSecond)
                    try? await Task.sleep(for: .seconds(Self.hold))
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: run)) { offset = end }
                    try? await Task.sleep(for: .seconds(run + Self.hold))
                } else {
                    try? await Task.sleep(for: .seconds(max(2, Defaults[.notificationIconOnlyDuration])))
                }
                guard !Task.isCancelled else { return }
                onFinish()
            }
    }
}

struct NotificationExpandedView: View {
    @ObservedObject private var manager = SystemNotificationManager.shared
    let notification: SystemNotification
    /// Pins the notification while it is on screen. A notch the user opened
    /// themselves holds it; one opened by the notification itself must not,
    /// or it would never expire.
    var holdWhileShown: Bool = true
    @State private var didHold = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: openSourceApp) {
                HStack(alignment: .center, spacing: 12) {
                    NotificationSourceIcon(bundleID: notification.bundleID, size: 46)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(notification.appName ?? "Notification")
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)

                            Text(notification.receivedAt, style: .relative)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }

                        if let title = notification.title, title != notification.appName {
                            Text(title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                        }

                        if let subtitle = notification.subtitle {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let body = notification.body {
                            Text(body)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary.opacity(0.9))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(notification.appName ?? "App") notification")
            .accessibilityHint("Opens \(notification.appName ?? "the app")")

            HStack(spacing: 4) {
                if !manager.queuedNotifications.isEmpty {
                    Button {
                        manager.showNextQueued()
                    } label: {
                        Text("+\(manager.queuedNotifications.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show next queued notification")
                }

                Button {
                    manager.dismissActive(token: notification.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification")
            }
            .padding(.trailing, 4)
        }
        .onAppear {
            guard holdWhileShown else { return }
            didHold = true
            manager.holdActive()
        }
        .onDisappear {
            guard didHold else { return }
            didHold = false
            manager.resumeDismiss()
        }
    }

    private func openSourceApp() {
        Task {
            guard await manager.open(notification) else { return }
            manager.dismissActive(token: notification.id)
        }
    }
}
