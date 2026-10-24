//
//  UsageWidgetView.swift
//  boringNotch
//
import SwiftUI

/// A Claude or Codex usage card that adapts to the cells it is given:
/// two rows tall draws a ring per rate-limit window, one row tall becomes a
/// horizontal strip that degrades gracefully as it gets narrower.
struct UsageWidgetView: View {
    let source: UsageSource
    let size: CGSize

    @ObservedObject private var store = UsageStore.shared

    private var snapshot: UsageSnapshot? { store.snapshots[source.id] }
    private var isStrip: Bool { size.height < 90 }
    private var title: String { snapshot?.title ?? source.displayName }
    private var icon: String { snapshot?.symbol ?? source.icon }

    var body: some View {
        Group {
            if isStrip {
                strip
            } else {
                card
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear { store.beginWatching() }
        .onDisappear { store.endWatching() }
    }

    // MARK: Two rows tall

    /// The age goes under the title, where it has room; a pill beside the
    /// title was cut down to a digit, most of all in Chinese.
    private var card: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let date = snapshot?.lastUpdatedDate
            let age = Freshness.text(of: date, at: context.date)
            let subtitle = [snapshot?.model, age].compactMap { $0 }.joined(separator: " · ")
            DashboardCard(icon: icon, tint: source.tint, title: title, subtitle: subtitle.isEmpty ? nil : subtitle) {
                FreshnessDot(date: date, now: context.date)
            } content: {
                if let snapshot {
                    rings(snapshot)
                } else {
                    emptyState
                }
            }
        }
    }

    @ViewBuilder
    private func rings(_ snapshot: UsageSnapshot) -> some View {
        let windows = snapshot.windows
        let bars = snapshot.bars
        let hasSubtitle = snapshot.model != nil || snapshot.lastUpdatedDate != nil
        let headerHeight: CGFloat = hasSubtitle ? 26 : 22
        // Padding, header, the bar rows, and the minimum gaps between them.
        let reserved: CGFloat = 18 + headerHeight + CGFloat(bars.count) * 14 + 22
        let byHeight = size.height - reserved
        let byWidth = (size.width - 18) / CGFloat(max(windows.count, 1)) - 8
        let diameter = min(max(min(byHeight, byWidth), 40), 64)

        Spacer(minLength: 4)
        HStack(spacing: 0) {
            ForEach(windows, id: \.title) { metric in
                GaugeRing(
                    fraction: metric.normalizedValue ?? 0,
                    valueText: metric.formattedValue,
                    label: metric.title,
                    tint: source.tint,
                    diameter: diameter
                )
                .frame(maxWidth: .infinity)
            }
        }
        // Spare height becomes equal gaps between the title, the rings and
        // the bars, with the last row sitting on the card's bottom padding.
        // With no bars the rings are centred under the title instead.
        Spacer(minLength: 6)
        ForEach(bars, id: \.title) { metric in
            GaugeBar(
                fraction: metric.normalizedValue ?? 0,
                valueText: metric.formattedValue,
                label: metric.title,
                tint: source.tint
            )
        }
    }

    // MARK: One row tall

    /// Widest layout that fits wins: title + all gauges + freshness, then
    /// without the freshness pill, then a stacked title/chips layout.
    private var strip: some View {
        DashboardCardChrome(tint: source.tint) {
            if let snapshot {
                let metrics = snapshot.windows + snapshot.bars
                ViewThatFits(in: .horizontal) {
                    stripRow(snapshot, metrics: metrics, showsPill: true)
                    stripRow(snapshot, metrics: metrics, showsPill: false)
                    stripStacked(snapshot, metrics: metrics)
                }
                .frame(maxHeight: .infinity)
            } else {
                emptyState
            }
        }
    }

    private func stripRow(_ snapshot: UsageSnapshot, metrics: [UsageMetric], showsPill: Bool) -> some View {
        HStack(spacing: 14) {
            DashboardCardTitle(icon: icon, tint: source.tint, title: title, subtitle: snapshot.model)
            ForEach(metrics, id: \.title) { metric in
                MiniGauge(
                    fraction: metric.normalizedValue ?? 0,
                    valueText: metric.formattedValue,
                    label: metric.title,
                    tint: source.tint
                )
            }
            if showsPill {
                FreshnessPill(date: snapshot.lastUpdatedDate)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func stripStacked(_ snapshot: UsageSnapshot, metrics: [UsageMetric]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            DashboardCardTitle(icon: icon, tint: source.tint, title: title)
            HStack(spacing: 8) {
                ForEach(metrics.prefix(3), id: \.title) { metric in
                    HStack(spacing: 3) {
                        Text(metric.title)
                            .foregroundStyle(.secondary)
                        Text(metric.formattedValue)
                            .fontWeight(.bold)
                            .foregroundStyle(usageGaugeColor(used: metric.normalizedValue ?? 0, tint: source.tint))
                    }
                    .font(.system(size: 10, design: .rounded))
                    .lineLimit(1)
                    .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        Text("No usage data yet")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
