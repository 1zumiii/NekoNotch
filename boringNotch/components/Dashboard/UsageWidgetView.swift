//
//  UsageWidgetView.swift
//  boringNotch
//
import Defaults
import SwiftUI

/// A Claude or Codex usage card that adapts to the cells it is given:
/// two rows tall draws a ring per rate-limit window, one row tall becomes a
/// horizontal strip that degrades gracefully as it gets narrower.
struct UsageWidgetView: View {
    let source: UsageSource
    let size: CGSize

    @ObservedObject private var store = UsageStore.shared
    @AppStorage("claudeQuotaClient") private var claudeClient = "app"
    @Default(.claudeMergeSameAccount) private var mergeSameAccount

    /// The quota card: Claude (App / CLI, or both merged) and Codex behind one switch.
    private var isClaude: Bool { source.id == "claude" }
    /// One account behind both Claude clients: one Claude tab, the fresher sample wins.
    private var isMerged: Bool { isClaude && mergeSameAccount && store.snapshots["claude"]?.sameAccount == true }
    private var showsCodex: Bool { isClaude && claudeClient == "codex" }
    /// The source on screen: its tint, icon and fallback title.
    private var shown: UsageSource { showsCodex ? .codex : source }
    /// Icons, not names: three names do not fit beside the title at 4 columns.
    private var tabs: [(label: String, icon: String, value: String)] {
        let codex = ("Codex", UsageSource.codex.icon, "codex")
        return isMerged
            ? [("Claude", UsageSource.claude.icon, "app"), codex]
            : [("Claude App", "macwindow", "app"), ("Claude CLI", "terminal", "cli"), codex]
    }
    private func isSelected(_ value: String) -> Bool {
        // Merged, the CLI choice is part of the single Claude tab.
        isMerged && value == "app" ? !showsCodex : claudeClient == value
    }
    private var snapshot: UsageSnapshot? {
        guard isClaude else { return store.snapshots[source.id] }
        if showsCodex { return store.snapshots["codex"]?.codexDisplay(at: Date()) }
        if isMerged {
            return UsageSnapshot.fresher(store.snapshots["claude"], store.snapshots["claudeCLI"], at: Date())
        }
        return store.snapshots[claudeClient == "cli" ? "claudeCLI" : "claude"]
    }
    private var isStrip: Bool { size.height < 90 }
    private var title: String { isClaude ? shown.displayName : snapshot?.title ?? source.displayName }
    private var icon: String { snapshot?.symbol ?? shown.icon }
    private var tint: Color { shown.tint }

    var body: some View {
        Group {
            if isStrip {
                if isClaude { claudeStrip } else { strip }
            } else {
                card
            }
        }
        .frame(width: size.width, height: size.height)
        .onAppear { store.beginWatching() }
        .onDisappear { store.endWatching() }
    }

    private var clientSelector: some View {
        HStack(spacing: 1) {
            ForEach(tabs, id: \.value) { tab in
                clientButton(tab.label, icon: tab.icon, value: tab.value)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .fixedSize()
    }

    private func clientButton(_ label: String, icon: String, value: String) -> some View {
        Button { claudeClient = value } label: {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isSelected(value) ? Color.white : Color.secondary)
                .frame(width: 20, height: 16)
                .background(Capsule().fill(isSelected(value) ? tint.opacity(0.40) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected(value) ? .isSelected : [])
    }

    private func sampleDescription(at now: Date) -> String {
        guard let snapshot else { return String(localized: "No usage data yet") }
        let age = Freshness.text(of: snapshot.lastUpdatedDate, at: now) ?? "—"
        let date = snapshot.lastUpdatedDate?.formatted(date: .abbreviated, time: .standard) ?? "—"
        return snapshot.title + " · " + age + "\n" + String(localized: "Updated") + ": " + date
    }

    private var claudeStrip: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            DashboardCardChrome(tint: tint) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(verbatim: title).font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                        clientSelector
                    }
                    HStack(spacing: 6) {
                        if let snapshot {
                            ForEach(snapshot.windows, id: \.title) { metric in
                                Text(verbatim: metric.title + " " + metric.formattedValue)
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            Spacer(minLength: 0)
                        } else {
                            Text("No usage data yet").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
            .help(sampleDescription(at: context.date))
        }
    }

    // MARK: Two rows tall

    /// The age goes under the title, where it has room; a pill beside the
    /// title was cut down to a digit, most of all in Chinese.
    private var card: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let date = snapshot?.lastUpdatedDate
            let age = Freshness.text(of: date, at: context.date)
            let subtitle = [snapshot?.model, age].compactMap { $0 }.joined(separator: " · ")
            DashboardCard(icon: icon, tint: tint, title: title, subtitle: subtitle.isEmpty ? nil : subtitle) {
                if isClaude { clientSelector } else { FreshnessDot(date: date, now: context.date) }
            } content: {
                if let snapshot {
                    rings(snapshot)
                } else {
                    emptyState
                }
            }
            .help(isClaude ? sampleDescription(at: context.date) : "")
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
                    tint: tint,
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
                tint: tint
            )        }
    }

    // MARK: One row tall

    /// Widest layout that fits wins: title + all gauges + freshness, then
    /// without the freshness pill, then a stacked title/chips layout.
    private var strip: some View {
        DashboardCardChrome(tint: tint) {
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
            DashboardCardTitle(icon: icon, tint: tint, title: title, subtitle: snapshot.model)
            ForEach(metrics, id: \.title) { metric in
                MiniGauge(
                    fraction: metric.normalizedValue ?? 0,
                    valueText: metric.formattedValue,
                    label: metric.title,
                    tint: tint
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
            DashboardCardTitle(icon: icon, tint: tint, title: title)
            HStack(spacing: 8) {
                ForEach(metrics.prefix(3), id: \.title) { metric in
                    HStack(spacing: 3) {
                        Text(metric.title)
                            .foregroundStyle(.secondary)
                        Text(metric.formattedValue)
                            .fontWeight(.bold)
                            .foregroundStyle(usageGaugeColor(used: metric.normalizedValue ?? 0, tint: tint))
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
