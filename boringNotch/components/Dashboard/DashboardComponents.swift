//
//  DashboardComponents.swift
//  boringNotch
//
//  Shared building blocks so every dashboard widget looks like it belongs to
//  the same family: a tinted card, a ring gauge, a bar gauge, a freshness pill.
//
import SwiftUI

/// Green-ish at rest, amber then red as a limit gets close.
func usageGaugeColor(used: Double, tint: Color) -> Color {
    switch used {
    case 0.9...: return Color(red: 1.0, green: 0.33, blue: 0.30)
    case 0.7...: return Color(red: 1.0, green: 0.70, blue: 0.20)
    default: return tint
    }
}

/// The tinted, bordered rounded rectangle every widget sits in. Content that
/// doesn't fit is clipped to the card instead of spilling over its neighbours.
struct DashboardCardChrome<Content: View>: View {
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [tint.opacity(0.16), Color.white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

/// Icon badge + title (+ optional monospaced subtitle).
struct DashboardCardTitle: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.18)))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The standard vertical card: title row, trailing accessory, then content.
struct DashboardCard<Trailing: View, Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        DashboardCardChrome(tint: tint) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    DashboardCardTitle(icon: icon, tint: tint, title: title, subtitle: subtitle)
                    Spacer(minLength: 4)
                    trailing
                }
                content
            }
        }
    }
}

/// A tiny labelled bar for single-row ("strip") layouts.
struct MiniGauge: View {
    let fraction: Double
    let valueText: String
    let label: String
    let tint: Color

    private var used: Double { min(max(fraction, 0), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(valueText)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(usageGaugeColor(used: used, tint: tint))
                        .frame(width: max(proxy.size.width * used, 5))
                }
            }
            .frame(height: 5)
        }
        .frame(minWidth: 64)
    }
}

/// A ring with the percentage inside and a small chip underneath.
struct GaugeRing: View {
    let fraction: Double
    let valueText: String
    let label: String
    let tint: Color
    let diameter: CGFloat

    private var used: Double { min(max(fraction, 0), 1) }
    private var color: Color { usageGaugeColor(used: used, tint: tint) }
    private var lineWidth: CGFloat { max(5, diameter * 0.12) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(used, 0.012))
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0.55), color],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(max(360 * used, 30))
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(label)
                    .font(.system(size: max(8, diameter * 0.15), weight: .semibold))
                    .foregroundStyle(.secondary)
                centerText
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.smooth(duration: 0.6), value: used)
    }

    @ViewBuilder
    private var centerText: some View {
        if valueText.hasSuffix("%") {
            (Text(valueText.dropLast())
                .font(.system(size: diameter * 0.27, weight: .bold, design: .rounded))
             + Text("%")
                .font(.system(size: diameter * 0.15, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        } else {
            Text(valueText)
                .font(.system(size: diameter * 0.22, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }
}

/// A labelled horizontal bar with the value on the right.
struct GaugeBar: View {
    let fraction: Double
    let valueText: String
    let label: String
    let tint: Color
    var labelWidth: CGFloat = 46

    private var used: Double { min(max(fraction, 0), 1) }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
                .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(usageGaugeColor(used: used, tint: tint))
                        .frame(width: max(proxy.size.width * used, 6))
                }
            }
            .frame(height: 6)
            .animation(.smooth(duration: 0.6), value: used)
            Text(valueText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// "9 hrs ago" with a dot: green when fresh, grey when a while old, orange
/// when stale. Stale numbers are still shown; the dot just says how old.
struct FreshnessPill: View {
    let date: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 5) {
                Circle().fill(color(at: context.date)).frame(width: 6, height: 6)
                Text(text(at: context.date))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.07)))
        }
    }

    private func age(at now: Date) -> TimeInterval? {
        date.map { now.timeIntervalSince($0) }
    }

    private func color(at now: Date) -> Color {
        guard let age = age(at: now) else { return .gray }
        if age < 3600 { return Color(red: 0.30, green: 0.80, blue: 0.45) }
        if age < 6 * 3600 { return .gray }
        return Color.orange
    }

    private func text(at now: Date) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
