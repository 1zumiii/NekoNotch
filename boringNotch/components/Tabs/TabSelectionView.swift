//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI
@_spi(Advanced) import SwiftUIIntrospect

struct TabModel: Identifiable {
    var id: NotchViews { view }
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Dashboard", icon: "square.grid.2x2.fill", view: .dashboard),
    TabModel(label: "Mixer", icon: "headphones", view: .mixer),
    TabModel(label: "Notifications", icon: "bell.fill", view: .notifications)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var history = NotificationHistory.shared
    @Default(.boringShelf) private var showShelf
    @Default(.showDashboardTab) private var showDashboard
    @Default(.showMixerTab) private var showMixer
    @Default(.notificationLiveActivity) private var showNotifications
    @Default(.notificationHistory) private var keepHistory

    private var visibleTabs: [TabModel] {
        tabs.filter {
            switch $0.view {
            case .home: true
            case .shelf: showShelf
            case .dashboard: showDashboard
            case .mixer: showMixer
            case .notifications: showNotifications && keepHistory
            }
        }
    }

    var body: some View {
        NotchTabStrip(
            tabs: visibleTabs,
            selection: $coordinator.currentView,
            hasUnseenNotifications: history.unseenCount > 0
        )
    }
}

/// Home stays anchored while the remaining tabs scroll inside the left wing.
struct NotchTabStrip: View {
    let tabs: [TabModel]
    @Binding var selection: NotchViews
    var hasUnseenNotifications = false

    @Namespace var animation
    @StateObject private var scrollObserver = TabScrollObserver()

    private let tabWidth: CGFloat = 40
    private let arrowWidth: CGFloat = 14
    private var contentOffset: CGFloat { scrollObserver.offset }
    private var scrollingTabs: [TabModel] { tabs.filter { $0.view != .home } }

    var body: some View {
        HStack(spacing: 4) {
            if let home = tabs.first(where: { $0.view == .home }) {
                tabButton(home)
            }
            GeometryReader { geometry in
                let contentWidth = CGFloat(scrollingTabs.count) * tabWidth
                let overflows = contentWidth > geometry.size.width
                // Hug the tabs when they fit so the backdrop doesn't stretch across the wing.
                let viewportWidth = overflows ? max(0, geometry.size.width - arrowWidth * 2) : contentWidth
                let canGoBack = overflows && contentOffset > 1
                let canGoForward = overflows && contentOffset + viewportWidth < contentWidth - 1

                ScrollViewReader { proxy in
                    HStack(spacing: 0) {
                        if overflows {
                            scrollButton(forward: false, enabled: canGoBack, proxy: proxy)
                        }
                        ScrollView(.horizontal) {
                            HStack(spacing: 0) {
                                ForEach(scrollingTabs) { tab in
                                    tabButton(tab).id(tab.id)
                                }
                            }
                        }
                        // `.hidden` still yields to "Always show scroll bars", whose
                        // legacy scroller takes height and pushes the icons up.
                        .scrollIndicators(.never)
                        .scrollDisabled(!overflows)
                        .frame(width: viewportWidth, height: 26)
                        .introspect(.scrollView, on: .macOS(.v14...)) { scrollView in
                            scrollView.hasHorizontalScroller = false
                            scrollView.hasVerticalScroller = false
                            scrollObserver.observe(scrollView)
                        }
                        .mask {
                            HStack(spacing: 0) {
                                LinearGradient(colors: [canGoBack ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 6)
                                Rectangle()
                                LinearGradient(colors: [.black, canGoForward ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 6)
                            }
                        }
                        if overflows {
                            scrollButton(forward: true, enabled: canGoForward, proxy: proxy)
                        }
                    }
                    .frame(height: 26)
                    // Sets the scrolling tabs apart from Home.
                    .background {
                        if !scrollingTabs.isEmpty {
                            Capsule().fill(Color.white.opacity(0.08))
                        }
                    }
                    .onAppear { revealSelection(using: proxy) }
                    .onDisappear { scrollObserver.stop() }
                    .onChange(of: selection) { revealSelection(using: proxy) }
                    .onChange(of: viewportWidth) { revealSelection(using: proxy) }
                    .onChange(of: scrollingTabs.map(\.id)) { revealSelection(using: proxy) }
                }
            }
        }
        // No `.clipped()`: the ScrollView clips its own tabs, and an outer clip
        // trails the opening animation by a few frames, cutting the backdrop.
        .frame(height: 26)
    }

    private func tabButton(_ tab: TabModel) -> some View {
        TabButton(label: tab.label, icon: tab.icon, selected: selection == tab.view) {
            withAnimation(.smooth) { selection = tab.view }
        }
        .foregroundStyle(selection == tab.view ? .white : .gray)
        .background {
            if selection == tab.view {
                Capsule()
                    .fill(Color(nsColor: .secondarySystemFill))
                    .matchedGeometryEffect(id: "capsule", in: animation)
            }
        }
        .overlay(alignment: .topTrailing) {
            if tab.view == .notifications, hasUnseenNotifications {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)
                    .offset(x: -6, y: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private func scrollButton(forward: Bool, enabled: Bool, proxy: ScrollViewProxy) -> some View {
        Button {
            let index = forward
                ? Int(floor(contentOffset / tabWidth)) + 1
                : Int(ceil(contentOffset / tabWidth)) - 1
            let target = min(max(0, index), scrollingTabs.count - 1)
            guard scrollingTabs.indices.contains(target) else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(scrollingTabs[target].id, anchor: .leading)
            }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: arrowWidth, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.25))
        .disabled(!enabled)
        .help(forward ? Text("Next") : Text("Previous"))
        .accessibilityLabel(forward ? Text("Next") : Text("Previous"))
    }

    private func revealSelection(using proxy: ScrollViewProxy) {
        // Returning to Home also restores the beginning of the scrolling row.
        guard let target = scrollingTabs.first(where: { $0.view == selection }) ?? scrollingTabs.first else { return }
        proxy.scrollTo(target.id, anchor: selection == .home ? .leading : .center)
    }
}

/// AppKit scrolls its clip view without necessarily re-evaluating SwiftUI
/// geometry preferences. Observe native bounds so arrows also follow trackpad
/// scrolling and ScrollViewReader animations on macOS 14 and later.
private final class TabScrollObserver: ObservableObject {
    @Published private(set) var offset: CGFloat = 0
    private weak var clipView: NSClipView?
    private var observer: NSObjectProtocol?

    func observe(_ scrollView: NSScrollView) {
        let clip = scrollView.contentView
        guard clip !== clipView else { return }
        stop()
        clipView = clip
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self, weak clip] _ in
            // Publish after the current layout pass has finished.
            DispatchQueue.main.async { [weak self, weak clip] in
                guard let self, let clip, clip === self.clipView else { return }
                self.updateOffset(clip.bounds.minX)
            }
        }
        DispatchQueue.main.async { [weak self, weak clip] in
            guard let self, let clip, clip === self.clipView else { return }
            self.updateOffset(clip.bounds.minX)
        }
    }

    private func updateOffset(_ value: CGFloat) {
        let value = max(0, value)
        if abs(offset - value) > 0.25 { offset = value }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        clipView = nil
    }

    deinit { stop() }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel(camera: CameraModel()))
}
