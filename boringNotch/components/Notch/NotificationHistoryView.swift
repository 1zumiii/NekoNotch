//
//  NotificationHistoryView.swift
//  boringNotch
//
import Defaults
import SwiftUI

/// The notifications tab: what reached the notch, newest first, so one that
/// went by unseen can still be read and opened. A summary on the left (count,
/// Focus, clear), the list on the right, like the mixer.
struct NotificationHistoryView: View {
    @ObservedObject private var history = NotificationHistory.shared
    @ObservedObject private var focus = FocusStatusMonitor.shared
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    static var isTabShown: Bool {
        Defaults[.notificationLiveActivity] && Defaults[.notificationHistory]
    }

    var body: some View {
        // Ages are words like "5 min. ago": once every half minute is plenty.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .center, spacing: 8) {
                summary
                    .frame(width: 150)
                    .frame(maxHeight: .infinity)

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1)
                    .padding(.vertical, 8)

                list(now: context.date)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.bottom, 2)
        .onAppear {
            // The tab can be switched off while it is the remembered one.
            if !Self.isTabShown {
                coordinator.currentView = .home
            } else {
                history.isViewing = true
            }
        }
        .onDisappear { history.isViewing = false }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(history.entries.count)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("notifications")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 5) {
                Image(systemName: focus.current?.symbol ?? "moon")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(focus.isFocused ? Color.indigo : Color.secondary)
                if let current = focus.current {
                    Text(verbatim: current.name ?? current.identifier)
                        .lineLimit(1)
                } else {
                    Text("No Focus")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                history.clear()
            } label: {
                Label("Clear All", systemImage: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(history.entries.isEmpty)
            .opacity(history.entries.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
    }

    // MARK: List

    @ViewBuilder
    private func list(now: Date) -> some View {
        if history.entries.isEmpty {
            // A single centred line, as in the mixer.
            HStack(spacing: 8) {
                Image(systemName: "bell.slash").font(.system(size: 16))
                Text("No notifications yet")
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // No row animations: rows moving while the list scrolls looked
            // broken in the clipboard list.
            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    ForEach(history.entries) { entry in
                        HistoryRow(entry: entry, now: now)
                    }
                }
            }
            .scrollIndicators(.never)
            .transaction { $0.animation = nil }
        }
    }
}

private struct HistoryRow: View {
    let entry: NotificationHistoryEntry
    let now: Date

    @State private var isHovering = false

    private var notification: SystemNotification { entry.notification }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                Task { _ = await SystemNotificationManager.shared.open(notification) }
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    NotificationSourceIcon(bundleID: notification.bundleID, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(verbatim: notification.appName ?? String(localized: "Notification"))
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            if entry.silenced {
                                Image(systemName: "moon.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.indigo)
                                    .help("Silenced by Focus")
                            }
                            Text(verbatim: Freshness.text(of: notification.receivedAt, at: now) ?? "")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .fixedSize()
                            Spacer(minLength: 0)
                        }
                        if let title = notification.title, title != notification.appName {
                            Text(verbatim: title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        if let text = bodyText {
                            Text(verbatim: text)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // Room for the remove button.
                    .padding(.trailing, 18)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(isHovering ? 0.1 : 0.06))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            if isHovering {
                Button {
                    NotificationHistory.shared.remove(entry)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Remove")
            }
        }
        .onHover { isHovering = $0 }
    }

    private var bodyText: String? {
        let parts = [notification.subtitle, notification.body].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
