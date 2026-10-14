//
//  MixerView.swift
//  boringNotch
//
import AppKit
import Defaults
import SwiftUI

/// The mixer tab. Two fixed cards on the left (system output, microphone) and
/// a list of the apps that are playing on the right. Each app row keeps only
/// the essentials in view: its volume with a live level, and a mute button.
/// Everything else (solo, output, balance, mono, reset) folds out of the row.
struct MixerView: View {
    @ObservedObject private var engine = AudioMixerEngine.shared
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @State private var expanded: String?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(spacing: 5) {
                SystemCard()
                MicrophoneCard()
            }
            .frame(width: 214)
            .frame(maxHeight: .infinity)

            // A faint rule between the fixed cards and the app list, inset a
            // little top and bottom so it doesn't touch the edges.
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)
                .padding(.vertical, 8)

            VStack(spacing: 4) {
                HStack {
                    Text("Apps")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ScenesMenu()
                }
                .frame(height: 18)
                .padding(.horizontal, 4)

                if engine.sources.isEmpty {
                    // A single centred line. (As an overlay on the scroll view
                    // the text was squeezed to the width of its empty content
                    // and wrapped one character per line.)
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 16))
                        Text("No apps are playing sound")
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 5) {
                            ForEach(engine.sources) { source in
                                AppRow(source: source, isExpanded: expanded == source.id) {
                                    withAnimation(.smooth(duration: 0.2)) {
                                        expanded = expanded == source.id ? nil : source.id
                                    }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.bottom, 2)
        .onAppear {
            // The tab can be switched off while it is the remembered one.
            if !Defaults[.showMixerTab] {
                coordinator.currentView = .home
            } else {
                engine.setMetersRequested(true)
            }
        }
        .onDisappear { engine.setMetersRequested(false) }
    }
}

// MARK: - Building blocks

private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
}

/// A horizontal fader. Drag along it, double-click to return to `unity`.
/// With a `level`, a thin live meter runs under the track. (Drawn inside the
/// track it would sit beneath the coloured fill and be hidden by it.)
private struct HorizontalFader: View {
    @Binding var value: Double
    var maxValue: Double = 1
    var unity: Double = 1
    var tint: Color = .accentColor
    var level: (() -> Float)?

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let fraction = CGFloat(min(max(value / maxValue, 0), 1))

                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1)).frame(height: 6)
                    Capsule().fill(tint).frame(width: max(6, width * fraction), height: 6)
                    if maxValue > unity {
                        Rectangle()
                            .fill(Color.white.opacity(0.4))
                            .frame(width: 1, height: 12)
                            .offset(x: width * CGFloat(unity / maxValue))
                    }
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: min(max(width * fraction - 7, 0), width - 14))
                }
                .frame(height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { drag in
                        value = Double(min(max(drag.location.x / width, 0), 1)) * maxValue
                    }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded { value = unity })
            }
            .frame(height: 14)

            if let level {
                MeterLine(read: level)
            }
        }
        .frame(height: level == nil ? 14 : 20)
    }
}

/// The live level line under a fader. It owns its refresh timer, so faders
/// without a level (system, microphone) run no timer at all.
private struct MeterLine: View {
    let read: () -> Float
    @State private var meter: CGFloat = 0
    private let timer = Timer.publish(every: 1.0 / 15.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                LinearGradient(
                    colors: [Color(red: 0.30, green: 0.80, blue: 0.45), .yellow, Color(red: 1, green: 0.33, blue: 0.30)],
                    startPoint: .leading, endPoint: .trailing
                )
                .clipShape(Capsule())
                .mask(alignment: .leading) {
                    Rectangle().frame(width: proxy.size.width * meter)
                }
            }
        }
        .frame(height: 3)
        .onReceive(timer) { _ in
            // A square root makes quiet audio visible without clipping loud audio.
            let raw = CGFloat(min(1, max(0, read()).squareRoot()))
            let next = max(raw, meter * 0.8)
            // Skip the redraw when the bar wouldn't visibly move.
            if abs(next - meter) > 0.004 { meter = next }
        }
    }
}

private struct SmallButton: View {
    let symbol: String?
    var label: String?
    var isOn = false
    var onColor: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                } else if let label {
                    Text(label).font(.system(size: 10, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(isOn ? Color.black : .secondary)
            .frame(width: 22, height: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? onColor : Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }
}

private func percentLabel(_ value: Double) -> some View {
    Text(verbatim: "\(Int((value * 100).rounded()))%")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .frame(width: 38, alignment: .trailing)
}

private func devicePicker(
    devices: [MixerOutputDevice], selected: String?, title: String?, symbol: String,
    select: @escaping (String) -> Void
) -> some View {
    Menu {
        ForEach(devices) { device in
            Button {
                select(device.uid)
            } label: {
                Label(device.name, systemImage: device.uid == selected ? "checkmark" : device.symbol)
            }
        }
    } label: {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(title ?? "—")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 7)).foregroundStyle(.secondary)
        }
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize(horizontal: false, vertical: true)
}

// MARK: - Fixed cards

private struct SystemCard: View {
    @ObservedObject private var engine = AudioMixerEngine.shared
    private var current: MixerOutputDevice? { engine.devices.first { $0.uid == engine.defaultOutputUID } }

    var body: some View {
        card {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    devicePicker(
                        devices: engine.devices, selected: engine.defaultOutputUID, title: current?.name,
                        symbol: current?.symbol ?? "speaker.wave.2", select: engine.setDefaultOutput
                    )
                    Spacer(minLength: 0)
                    SmallButton(
                        symbol: engine.systemMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                        isOn: engine.systemMuted, onColor: .red
                    ) { engine.setSystemMuted(!engine.systemMuted) }
                }
                if let volume = engine.systemVolume {
                    HStack(spacing: 6) {
                        HorizontalFader(value: Binding(get: { volume }, set: { engine.setSystemVolume($0) }))
                        percentLabel(engine.systemMuted ? 0 : volume)
                    }
                } else {
                    Text("This output has no volume control")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(height: 18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MicrophoneCard: View {
    @ObservedObject private var engine = AudioMixerEngine.shared
    private var current: MixerOutputDevice? { engine.inputDevices.first { $0.uid == engine.defaultInputUID } }

    var body: some View {
        card {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    devicePicker(
                        devices: engine.inputDevices, selected: engine.defaultInputUID, title: current?.name,
                        symbol: "mic.fill", select: engine.setDefaultInput
                    )
                    Spacer(minLength: 0)
                    SmallButton(
                        symbol: engine.inputMuted ? "mic.slash.fill" : "mic.fill",
                        isOn: engine.inputMuted, onColor: .red
                    ) { engine.setInputMuted(!engine.inputMuted) }
                }
                if let volume = engine.inputVolume {
                    HStack(spacing: 6) {
                        HorizontalFader(
                            value: Binding(get: { volume }, set: { engine.setInputVolume($0) }),
                            tint: Color(red: 0.95, green: 0.45, blue: 0.40)
                        )
                        percentLabel(engine.inputMuted ? 0 : volume)
                    }
                } else {
                    Text("This input has no volume control")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(height: 18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App rows

private struct AppRow: View {
    let source: MixerSource
    let isExpanded: Bool
    let toggle: () -> Void
    @ObservedObject private var engine = AudioMixerEngine.shared

    private var setting: MixerAppSetting { engine.setting(for: source.id) }
    private var effectiveVolume: Double { setting.muted ? 0 : setting.volume }
    private var silencedBySolo: Bool { engine.solo != nil && engine.solo != source.id }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                icon.frame(width: 24, height: 24)

                Text(source.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(width: 84, alignment: .leading)

                HorizontalFader(
                    value: Binding(
                        get: { effectiveVolume },
                        set: { value in
                            if setting.muted { engine.setMuted(false, for: source.id) }
                            engine.setVolume(value, for: source.id)
                        }
                    ),
                    maxValue: 1.5,
                    tint: silencedBySolo ? .gray : .accentColor,
                    level: { engine.level(for: source.id) }
                )

                percentLabel(effectiveVolume)

                if let message = engine.errors[source.id] {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(message)
                }

                SmallButton(
                    symbol: setting.muted ? "speaker.slash.fill" : "speaker.fill",
                    isOn: setting.muted, onColor: .red
                ) { engine.setMuted(!setting.muted, for: source.id) }

                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hasCustomisation ? Color.accentColor : .secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16, height: 20)
                }
                .buttonStyle(.plain)
            }
            // The whole line opens the row, not just the small arrow. The
            // slider and the buttons keep their own taps, so only the empty
            // parts (icon, name, gaps, padding) toggle it.
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            if isExpanded {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
        .opacity(source.isPlaying ? 1 : 0.55)
    }

    /// A dot of colour on the arrow when something folded away is in effect.
    private var hasCustomisation: Bool {
        setting.outputUID != nil || abs(setting.balance) >= 0.01 || setting.mono || engine.solo == source.id
    }

    @ViewBuilder
    private var icon: some View {
        if let path = source.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit()
        } else {
            Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    // MARK: Folded-out controls

    private var details: some View {
        HStack(spacing: 6) {
            SmallButton(symbol: nil, label: "S", isOn: engine.solo == source.id, onColor: .yellow) {
                engine.toggleSolo(source.id)
            }
            .help(String(localized: "Solo: mute every other app"))

            SmallButton(symbol: nil, label: "M", isOn: setting.mono, onColor: .accentColor) {
                engine.setMono(!setting.mono, for: source.id)
            }
            .help(String(localized: "Mono"))

            routeMenu

            SmallButton(symbol: "arrow.counterclockwise") { engine.resetApp(source.id) }
                .disabled(setting.isUntouched)
                .help(String(localized: "Reset this app"))

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 14)

            HStack(spacing: 4) {
                Text("L").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { setting.balance }, set: { engine.setBalance($0, for: source.id) }),
                    in: -1...1
                )
                .controlSize(.mini)
                Text("R").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .help(String(localized: "Balance"))
        }
    }

    private var routeMenu: some View {
        Menu {
            Button {
                engine.setOutput(nil, for: source.id)
            } label: {
                Label("System default", systemImage: setting.outputUID == nil ? "checkmark" : "arrow.triangle.branch")
            }
            Divider()
            ForEach(engine.devices) { device in
                Button {
                    engine.setOutput(device.uid, for: source.id)
                } label: {
                    Label(device.name, systemImage: device.uid == setting.outputUID ? "checkmark" : device.symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: setting.outputUID == nil ? "arrow.triangle.branch" : "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(routeTitle)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(setting.outputUID == nil ? Color.secondary : Color.black)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(setting.outputUID == nil ? Color.white.opacity(0.1) : Color.accentColor))
            .frame(maxWidth: 120)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var routeTitle: String {
        if let uid = setting.outputUID, let device = engine.devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return String(localized: "System default")
    }
}

// MARK: - Scenes

/// Save the current app volumes as a scene, or jump back to one.
private struct ScenesMenu: View {
    @ObservedObject private var engine = AudioMixerEngine.shared

    var body: some View {
        Menu {
            if engine.scenes.isEmpty {
                Text("No saved scenes")
            }
            ForEach(engine.scenes) { scene in
                Button(scene.name) { engine.applyScene(scene) }
            }
            Divider()
            Button("Save current volumes as a scene…") { promptAndSave() }
            if !engine.scenes.isEmpty {
                Menu("Delete scene") {
                    ForEach(engine.scenes) { scene in
                        Button(scene.name, role: .destructive) { engine.deleteScene(scene) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bookmark.fill").font(.system(size: 9, weight: .semibold))
                Text("Scenes").font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func promptAndSave() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Save current volumes as a scene")
        alert.informativeText = String(localized: "Give the scene a name. Saving under an existing name replaces it.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "Scene name")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            engine.saveScene(named: field.stringValue)
        }
    }
}
