//
//  OnboardingView.swift
//  boringNotch
//
//  First-run setup in three steps: meet NekoNotch, turn on what you want,
//  and go. Each feature asks for its own permission, and only when its
//  button is pressed; skipping everything still finishes setup. The left
//  side shows the closed notch with the real rainbow cat and labelled sample
//  content: nothing there reads real data or reflects real permissions.
//
import AVFoundation
import ApplicationServices
import Defaults
import EventKit
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, features, ready

    var title: LocalizedStringKey {
        switch self {
        case .welcome: "Meet"
        case .features: "Set Up"
        case .ready: "Ready"
        }
    }
}

private let calendarService = CalendarService()

private enum Feature: CaseIterable, Identifiable {
    case music, notifications, calendar, mirror
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .music: "Music Control"
        case .notifications: "Notifications & System Indicators"
        case .calendar: "Calendar & Reminders"
        case .mirror: "Mirror"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .music: "See and control what's playing in the notch."
        case .notifications: "Notifications, and volume and brightness changes, in the notch."
        case .calendar: "Your next events and reminders at a glance."
        case .mirror: "Check yourself with the camera when you need to."
        }
    }

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .notifications: "bell.badge"
        case .calendar: "calendar"
        case .mirror: "camera"
        }
    }
}

/// Where a permission stands. `unconfirmed` is for one the system offers no
/// way to read back (system audio recording): shown as such, never as granted.
private enum PermissionState {
    case granted, notAsked, needsSettings, unconfirmed

    var label: LocalizedStringKey {
        switch self {
        case .granted: "Allowed"
        case .notAsked: "Not set up"
        case .needsSettings: "Turn on in System Settings"
        case .unconfirmed: "Not confirmed"
        }
    }

    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .notAsked, .unconfirmed: "circle.dashed"
        case .needsSettings: "exclamationmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .granted: .green
        case .notAsked, .unconfirmed: .secondary
        case .needsSettings: .orange
        }
    }
}

/// A feature as a whole: on, not set up, or on but waiting for a permission.
private enum FeatureStatus {
    case on, notSet, needsSettings

    var label: LocalizedStringKey {
        switch self {
        case .on: "On"
        case .notSet: "Not set up"
        case .needsSettings: "Turn on in System Settings"
        }
    }

    var symbol: String {
        switch self {
        case .on: "checkmark.circle.fill"
        case .notSet: "circle.dashed"
        case .needsSettings: "exclamationmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .on: .green
        case .notSet: .secondary
        case .needsSettings: .orange
        }
    }
}

private enum Demo: CaseIterable {
    case music, notification, monitor

    var title: LocalizedStringKey {
        switch self {
        case .music: "Music"
        case .notification: "Notifications"
        case .monitor: "System Monitor"
        }
    }
}

/// The permissions a "Go to System Settings" button can send the user to.
private enum SettingsPage: Hashable {
    case accessibility, fullDiskAccess, camera, calendars, reminders

    var url: URL? {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .camera: "Privacy_Camera"
        case .calendars: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

struct OnboardingView: View {
    @State var step: OnboardingStep = .welcome
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    static let size = CGSize(width: 1000, height: 620)
    /// The deep-space colours of the rainbow cat's sky.
    private static let panel = Color(red: 0.075, green: 0.082, blue: 0.118)
    private static let sky = Color(red: 0.047, green: 0.051, blue: 0.078)

    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.notificationLiveActivity) private var notifications
    @Default(.osdReplacement) private var osdReplacement
    @Default(.notificationFromDatabase) private var fromDatabase
    @Default(.showCalendar) private var showCalendar
    @Default(.showMirror) private var showMirror
    @Default(.appLanguage) private var appLanguage
    /// A language was picked; it applies after a restart, which brings setup
    /// back in that language since first launch hasn't ended.
    @State private var languageChanged = false

    @State private var detail: Feature?
    @State private var demo: Demo = .music
    @State private var showsMoreNotificationFeatures = false
    /// Pages of System Settings opened from here, which then show what to
    /// do there and a "Check Again" button.
    @State private var openedSettings: Set<SettingsPage> = []
    /// Only known once asked for in this setup; macOS can't be queried.
    @State private var audioCaptureGranted: Bool?
    /// Bumped every second and on coming back to the app, so a permission
    /// granted in System Settings shows up without a click.
    @State private var statusTick = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                preview
                    .frame(width: 380)
                ScrollView {
                    content
                        .padding(.horizontal, 44)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Self.panel)
        .environment(\.colorScheme, .dark)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in statusTick &+= 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            statusTick &+= 1
        }
        .task { musicManager.ensureNowPlayingAvailabilityChecked() }
    }

    // MARK: Frame

    private var header: some View {
        HStack(spacing: 24) {
            ForEach(OnboardingStep.allCases, id: \.self) { item in
                HStack(spacing: 6) {
                    Text(verbatim: "\(item.rawValue + 1)")
                        .monospacedDigit()
                    Text(item.title)
                }
                .font(.system(size: 13, weight: item == step ? .semibold : .regular))
                .foregroundStyle(item == step ? Color.accentColor : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .overlay(alignment: .trailing) {
            if step == .welcome {
                languagePicker.padding(.trailing, 20)
            }
        }
    }

    private var languagePicker: some View {
        HStack(spacing: 8) {
            if languageChanged {
                Button("Restart Now") { ApplicationRelauncher.restart() }
                    .controlSize(.small)
            }
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            Picker("Language", selection: $appLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .onChange(of: appLanguage) {
                appLanguage.applyAppleLanguagesOverride()
                languageChanged = true
            }
        }
        .help(Text("Changing the app language requires restarting NekoNotch."))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            switch step {
            case .welcome:
                Button("Start Without Setup") { finish() }
                    .buttonStyle(.borderless)
                Spacer()
                primaryButton("Set Up What I Need") { go(to: .features) }
            case .features:
                Button("Set Up Later") { go(to: .ready) }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Back") { go(to: .welcome) }
                    .buttonStyle(.borderless)
                primaryButton("Continue") { go(to: .ready) }
            case .ready:
                Button("Open Settings") {
                    Self.endFirstLaunch()
                    onOpenSettings()
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("Back") { go(to: .features) }
                    .buttonStyle(.borderless)
                primaryButton("Start Using") { finish() }
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 64)
    }

    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "arrow.right")
            }
            .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private func go(to next: OnboardingStep) {
        // The notch doesn't open on hover during first launch; the last step
        // asks the user to try it, so first launch ends there.
        if next == .ready { Self.endFirstLaunch() }
        withAnimation(.easeInOut(duration: 0.25)) {
            detail = nil
            step = next
        }
    }

    private func finish() {
        Self.endFirstLaunch()
        onFinish()
    }

    /// Set when system audio recording was granted during this setup; macOS
    /// offers no other way to know.
    @MainActor private static var audioCaptureConfirmed = false

    /// Ends first launch, once. Features are on by default; on the way out of
    /// the first setup, each one whose permission was not granted is turned
    /// off, so nothing asks for it later out of the blue. Running setup again
    /// from Settings leaves the settings alone.
    @MainActor static func endFirstLaunch() {
        let coordinator = BoringViewCoordinator.shared
        guard coordinator.firstLaunch else { return }
        if !AXIsProcessTrusted() {
            Defaults[.notificationLiveActivity] = false
            if Defaults[.osdBrightnessSource] == .builtin || Defaults[.osdVolumeSource] == .builtin {
                Defaults[.osdReplacement] = false
            }
        }
        if !NotificationDatabaseWatcher.hasAccess() {
            Defaults[.notificationFromDatabase] = false
            Defaults[.notificationEarlyPlaceholder] = false
        }
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            Defaults[.showCalendar] = false
        }
        if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            Defaults[.showMirror] = false
        }
        if !audioCaptureConfirmed {
            Defaults[.realtimeAudioWaveform] = false
        }
        coordinator.firstLaunch = false
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            Self.sky
            VStack(spacing: 20) {
                Spacer(minLength: 0)
                screen
                if step == .welcome {
                    demoPicker
                }
                VStack(spacing: 6) {
                    Text(caption)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(verbatim: "NEKONOTCH")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .environment(\.colorScheme, .dark)
    }

    private var caption: LocalizedStringKey {
        switch step {
        case .welcome: "Your notch has a new companion."
        case .features: "Turn on what you like."
        case .ready: "Just look up."
        }
    }

    /// A screen with the closed notch: the left wing's sky, the cutout and
    /// the cat's wing, as on the real notch, enlarged.
    private var screen: some View {
        let wing = RainbowCatNSView.wingWidth
        let height = RainbowCatNSView.size.height
        let cutout: CGFloat = 64
        let barWidth = 2 * wing + cutout
        let scale = min(1.4, 284 / barWidth)
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.09, green: 0.1, blue: 0.15), Color(red: 0.04, green: 0.045, blue: 0.07)],
                    startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
            VStack(spacing: 26) {
                HStack(spacing: 0) {
                    RainbowStars()
                        .frame(width: wing, height: height)
                        .clipped()
                    Color.black.frame(width: cutout, height: height)
                    // Not active: a sample, so the notes come at a steady pace
                    // rather than following whatever is really playing.
                    RainbowCat(isPlaying: step == .welcome && demo == .music, isActive: false)
                        .frame(width: wing, height: height)
                }
                .background(.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
                .scaleEffect(scale, anchor: .top)
                .frame(width: barWidth * scale, height: height * scale)
                sampleCard
            }
        }
        .frame(width: 312, height: 210)
    }

    private var demoPicker: some View {
        HStack(spacing: 6) {
            ForEach(Demo.allCases, id: \.self) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { demo = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: demo == item ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(demo == item ? 0.16 : 0.05)))
                        .foregroundStyle(.white.opacity(demo == item ? 1 : 0.6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Sample content, marked as such.
    @ViewBuilder
    private var sampleCard: some View {
        Group {
            if step == .ready {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up")
                    Text("Move the pointer to the top of the screen")
                }
            } else {
                switch demo {
                case .music:
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [.pink, .purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "Night Walk").font(.system(size: 13, weight: .semibold))
                            Text("Sample song").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "backward.fill")
                        Image(systemName: "pause.fill")
                        Image(systemName: "forward.fill")
                    }
                case .notification:
                    HStack(spacing: 10) {
                        Image(systemName: "calendar")
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.85)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Calendar").font(.system(size: 13, weight: .semibold))
                            Text("Design review in 10 minutes").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer(minLength: 0)
                    }
                case .monitor:
                    HStack(spacing: 0) {
                        sampleMetric("CPU", "23%")
                        sampleMetric("Memory", "61%")
                        sampleMetric("Network", "1.2 MB/s")
                    }
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: 256)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(alignment: .topTrailing) {
            if step != .ready {
                Text("Sample")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 5)
                    .padding(.trailing, 8)
            }
        }
    }

    private func sampleMetric(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            Text(verbatim: value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .features:
            if let detail {
                featureDetail(detail)
            } else {
                featureList
            }
        case .ready: ready
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium))
            .tracking(2)
            .foregroundStyle(.secondary)
    }

    private func heading(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(body)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("HELLO, NEKONOTCH")
            heading("Make more of your notch.",
                    "Music, notifications and handy tools, right where you look. And a piano cat to keep you company.")
                .padding(.top, 8)
            VStack(spacing: 0) {
                introRow("Control at hand", "See what's playing and adjust the volume.", "music.note")
                Divider()
                introRow("Fewer interruptions", "Read notifications and your schedule in the notch.", "bell")
                Divider()
                introRow("A little company", "Listen to music and keep an eye on your Mac.", "sparkles")
            }
            .padding(.top, 24)
        }
    }

    private func introRow(_ title: LocalizedStringKey, _ text: LocalizedStringKey, _ symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("MAKE IT YOURS")
            heading("Turn on what suits you.",
                    "Set up only what you need; the rest can wait. Everything can be changed later in Settings.")
                .padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(Feature.allCases) { feature in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { detail = feature }
                    } label: {
                        featureRow(feature)
                    }
                    .buttonStyle(.plain)
                    if feature != Feature.allCases.last { Divider() }
                }
            }
            .padding(.top, 20)
        }
    }

    private func featureRow(_ feature: Feature) -> some View {
        HStack(spacing: 14) {
            Image(systemName: feature.symbol)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title).font(.system(size: 14, weight: .semibold))
                Text(feature.summary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            featureStatusLabel(feature)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func featureStatusLabel(_ feature: Feature) -> some View {
        if feature == .music {
            Text(sourceName(musicManager.preferredMediaController))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            let status = status(of: feature)
            Label(status.label, systemImage: status.symbol)
                .font(.system(size: 12))
                .foregroundStyle(status.color)
        }
    }

    // MARK: Feature details

    @ViewBuilder
    private func featureDetail(_ feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { detail = nil }
            } label: {
                Label("All Features", systemImage: "chevron.left")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .padding(.bottom, 14)

            switch feature {
            case .music: musicDetail
            case .notifications: notificationsDetail
            case .calendar: calendarDetail
            case .mirror: mirrorDetail
            }
        }
    }

    private func sourceName(_ controller: MediaControllerType) -> String {
        controller == .nowPlaying ? String(localized: "Automatic detection") : controller.localizedString
    }

    private var musicDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Choose where music comes from.", "You can change this later in Settings.")
            VStack(spacing: 0) {
                ForEach(MediaControllerType.allCases) { controller in
                    let enabled = controller != .nowPlaying || musicManager.nowPlayingAvailability.isSelectable
                    let selected = musicManager.preferredMediaController == controller
                    Button {
                        musicManager.selectMediaController(controller)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selected ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(controller == .nowPlaying
                                     ? String(localized: "Automatic (recommended)")
                                     : controller.localizedString)
                                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                                if selected {
                                    sourceNote(controller)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.45)
                    if controller != MediaControllerType.allCases.last { Divider() }
                }
            }
            if let message = musicManager.nowPlayingAvailability.settingsMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if #available(macOS 14.2, *) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Follow the music (optional)").font(.system(size: 14, weight: .semibold))
                    Text("Draws the waveform and the cat's notes from the music that's playing; the mixer needs it too. Audio is analysed on this Mac and never recorded or saved.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    permissionRow(
                        "System Audio Recording",
                        state: audioCaptureGranted == true ? .granted : .unconfirmed,
                        settings: nil
                    ) {
                        Task {
                            let granted = await AudioCaptureManager.shared.requestAudioCapturePermission()
                            audioCaptureGranted = granted
                            if granted {
                                Self.audioCaptureConfirmed = true
                                Defaults[.realtimeAudioWaveform] = true
                            }
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func sourceNote(_ controller: MediaControllerType) -> some View {
        switch controller {
        case .nowPlaying:
            Text("Uses what macOS reports as playing; works with most players and browsers.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        case .youtubeMusic:
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.descriptionResource).font(.system(size: 12)).foregroundStyle(.secondary)
                if let url = URL(string: "https://github.com/pear-devs/pear-desktop") {
                    Link("See how to set it up", destination: url).font(.system(size: 12))
                }
            }
        default:
            Text(controller.descriptionResource).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var notificationsDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Notifications & system indicators.",
                    "Show supported notification banners, and volume and brightness changes, in the notch.")
            VStack(spacing: 0) {
                switchRow("Show notifications in the notch", isOn: $notifications)
                Divider()
                switchRow("Replace the volume and brightness indicators", isOn: $osdReplacement)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: AccessibilityPermission.displayName).font(.system(size: 14, weight: .semibold))
                Text("Reads notification banners, and the volume and brightness keys.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                permissionRow(nil, state: accessibilityState, settings: .accessibility) {
                    Task { _ = await MediaKeyInterceptor.shared.ensureAccessibilityAuthorization(promptIfNeeded: true) }
                }
            }
            DisclosureGroup("More notification features", isExpanded: $showsMoreNotificationFeatures) {
                VStack(alignment: .leading, spacing: 8) {
                    switchRow("Read the notification history and Focus (optional)", isOn: $fromDatabase)
                    Text("Reads the Notification Center database on this Mac to add notifications whose banners are off, and detects which Focus is on.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Full Disk Access").font(.system(size: 14, weight: .semibold)).padding(.top, 4)
                    permissionRow(nil, state: fullDiskAccessState, settings: .fullDiskAccess)
                }
                .padding(.top, 8)
            }
            .font(.system(size: 14, weight: .semibold))
        }
    }

    private var calendarDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Calendar & reminders.", "Read on this Mac only, to show in the notch.")
            switchRow("Show your schedule in the notch", isOn: $showCalendar)
            VStack(alignment: .leading, spacing: 6) {
                Text("Calendar").font(.system(size: 14, weight: .semibold))
                Text("See upcoming events.").font(.system(size: 12)).foregroundStyle(.secondary)
                permissionRow(nil, state: eventKitState(.event), settings: .calendars) {
                    Task { _ = try? await calendarService.requestAccess(to: .event); statusTick &+= 1 }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Reminders").font(.system(size: 14, weight: .semibold))
                Text("See reminders with a set time.").font(.system(size: 12)).foregroundStyle(.secondary)
                permissionRow(nil, state: eventKitState(.reminder), settings: .reminders) {
                    Task { _ = try? await calendarService.requestAccess(to: .reminder); statusTick &+= 1 }
                }
            }
        }
    }

    private var mirrorDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Need a mirror? Take a look.", "Preview your camera in the notch.")
            switchRow("Show the mirror in the notch", isOn: $showMirror)
            VStack(alignment: .leading, spacing: 6) {
                Text("Camera").font(.system(size: 14, weight: .semibold))
                Text("The camera is used only while the mirror is open; nothing is recorded or saved.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if cameraState == .granted {
                    Label("Allowed · Open the mirror in the notch to try it", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                } else {
                    permissionRow(nil, state: cameraState, settings: .camera, allowTitle: "Allow Camera Access") {
                        Task { _ = await AVCaptureDevice.requestAccess(for: .video); statusTick &+= 1 }
                    }
                }
            }
        }
    }

    /// A setting across the whole width: its label on the left, the switch
    /// on the right.
    private func switchRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 14))
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 8)
    }

    /// A permission's state and the one button that moves it on: asking the
    /// system where it can, otherwise opening the right page of System
    /// Settings, after which the steps and "Check Again" show.
    @ViewBuilder
    private func permissionRow(
        _ title: LocalizedStringKey?,
        state: PermissionState,
        settings: SettingsPage?,
        allowTitle: LocalizedStringKey = "Allow Access",
        request: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let title {
                    Text(title).font(.system(size: 13))
                }
                Label(state.label, systemImage: state.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(state.color)
                Spacer(minLength: 8)
                switch state {
                case .granted:
                    EmptyView()
                case .notAsked, .unconfirmed:
                    if let request {
                        Button(allowTitle, action: request)
                    } else if let settings {
                        settingsButton(settings)
                    }
                case .needsSettings:
                    if let settings { settingsButton(settings) }
                }
            }
            if let settings, openedSettings.contains(settings), state != .granted {
                HStack(spacing: 10) {
                    Text("Turn on NekoNotch in the list, then come back here. The status updates by itself.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Check Again") { statusTick &+= 1 }
                        .controlSize(.small)
                }
            }
        }
    }

    private func settingsButton(_ page: SettingsPage) -> some View {
        Button("Go to System Settings") {
            if page == .accessibility {
                // Asking first puts the app in the list to switch on.
                Task { _ = await MediaKeyInterceptor.shared.ensureAccessibilityAuthorization(promptIfNeeded: true) }
            }
            if let url = page.url { NSWorkspace.shared.open(url) }
            openedSettings.insert(page)
        }
    }

    // MARK: Ready

    private var ready: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow("ALL SET")
            heading("All set. Take a look at the notch.",
                    "Move the pointer to the notch at the top of the screen to open NekoNotch.")
                .padding(.top, 8)
            VStack(spacing: 0) {
                summaryRow("Music source", Text(sourceName(musicManager.preferredMediaController)))
                Divider()
                summaryRow(Feature.notifications.title, summaryText(status(of: .notifications)))
                Divider()
                summaryRow(Feature.calendar.title, summaryText(status(of: .calendar)))
                Divider()
                summaryRow(Feature.mirror.title, summaryText(status(of: .mirror)))
            }
            .padding(.top, 24)
        }
    }

    private func summaryText(_ status: FeatureStatus) -> Text {
        switch status {
        case .on: Text("On")
        case .notSet: Text("Set up later")
        case .needsSettings: Text("Turn on in System Settings")
        }
    }

    private func summaryRow(_ title: LocalizedStringKey, _ value: Text) -> some View {
        HStack {
            Text(title).font(.system(size: 14))
            Spacer()
            value.font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 11)
    }

    // MARK: Status

    private var accessibilityState: PermissionState {
        _ = statusTick
        return AXIsProcessTrusted() ? .granted : .needsSettings
    }

    private var fullDiskAccessState: PermissionState {
        _ = statusTick
        return NotificationDatabaseWatcher.hasAccess() ? .granted : .needsSettings
    }

    private var cameraState: PermissionState {
        _ = statusTick
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .needsSettings
        }
    }

    private func eventKitState(_ type: EKEntityType) -> PermissionState {
        _ = statusTick
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return .granted
        case .notDetermined: return .notAsked
        default: return .needsSettings
        }
    }

    private func status(of feature: Feature) -> FeatureStatus {
        switch feature {
        case .music:
            return .on
        case .notifications:
            guard notifications || osdReplacement else { return .notSet }
            return accessibilityState == .granted ? .on : .needsSettings
        case .calendar:
            guard showCalendar else { return .notSet }
            switch eventKitState(.event) {
            case .granted: return .on
            case .needsSettings: return .needsSettings
            default: return .notSet
            }
        case .mirror:
            guard showMirror else { return .notSet }
            switch cameraState {
            case .granted: return .on
            case .needsSettings: return .needsSettings
            default: return .notSet
            }
        }
    }
}

extension MediaControllerType {
    var descriptionResource: LocalizedStringResource {
        switch self {
        case .nowPlaying:
            LocalizedStringResource(
                "Works with most media apps, including browsers, to detect what's playing. Note: This may be removed in a future macOS version.",
                comment: "Onboarding description of the universal macOS Now Playing music source."
            )
        case .spotify:
            LocalizedStringResource(
                "Connects directly to the Spotify app.",
                comment: "Onboarding description of the Spotify music source."
            )
        case .appleMusic:
            LocalizedStringResource(
                "Connects directly to the Apple Music app.",
                comment: "Onboarding description of the Apple Music source."
            )
        case .youtubeMusic:
            LocalizedStringResource(
                "Requires a third-party client with API plugin enabled.",
                comment: "Onboarding description of the YouTube Music source."
            )
        }
    }
}
