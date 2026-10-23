//
//  AudioMixerEngine.swift
//  boringNotch
//
//  How it works: for an app the user has changed, a Core Audio process tap
//  captures its audio and mutes the original; a private aggregate device made
//  of the chosen output device plus that tap lets one IO callback copy the tap
//  to the output scaled by the volume. Apps left at their defaults get no tap
//  and are not touched at all.
//
import AppKit
import AudioToolbox
import CoreAudio
import Defaults
import Foundation

// MARK: - Core Audio helpers

private enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as type: T.Type
    ) -> T? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    static func string(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var reference: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &reference) == noErr,
              let reference else { return nil }
        return reference.takeRetainedValue() as String
    }

    static func objects(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func setValue<T>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ newValue: T
    ) -> Bool {
        var addr = address(selector, scope: scope)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &addr, &settable) == noErr, settable.boolValue else { return false }
        var copy = newValue
        return AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &copy) == noErr
    }
}

// MARK: - Render state shared with the audio thread

/// Only plain numbers live here, so the real-time callback never touches
/// anything that could block or retain.
private final class MixerRenderState {
    var targetGain: Float = 1
    var currentGain: Float = 1
    var leftScale: Float = 1
    var rightScale: Float = 1
    var mono = false
    var peakIn: Float = 0
    var peakOut: Float = 0
    var callbacks: Int = 0
}

/// A listen-only tap that measures an app's level without touching its sound.
private final class MixerMeterSession {
    private let state = MixerRenderState()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "boringnotch.mixer.meter", qos: .utility)
    private(set) var processObjects: [AudioObjectID]

    var level: Float { state.peakIn }

    init?(processObjects: [AudioObjectID]) {
        self.processObjects = processObjects
        guard #available(macOS 14.2, *) else { return nil }
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.isExclusive = false
        var newTap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &newTap) == noErr, newTap != kAudioObjectUnknown else { return nil }
        tapID = newTap
        guard let tapUID = CA.string(tapID, kAudioTapPropertyUID) else { teardown(); return nil }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "boringNotchMeter",
            kAudioAggregateDeviceUIDKey: "com.boringnotch.meter.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: "",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 0]]
        ]
        var newAggregate = AudioDeviceID(0)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate) == noErr, newAggregate != 0 else {
            teardown(); return nil
        }
        aggregateID = newAggregate

        let state = self.state
        var newProc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, queue) { _, inInput, _, _, _ in
            var peak: Float = 0
            for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput)) {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count { peak = max(peak, abs(samples[index])) }
            }
            state.peakIn = peak
        }
        guard status == noErr, let proc = newProc else { teardown(); return nil }
        ioProc = proc
        guard AudioDeviceStart(aggregateID, proc) == noErr else { teardown(); return nil }
    }

    deinit { teardown() }

    func teardown() {
        if aggregateID != 0, let proc = ioProc {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProc = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

// MARK: - One tapped app

private final class MixerSession {
    let key: String
    let outputUID: String
    private let state = MixerRenderState()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "boringnotch.mixer.io", qos: .userInteractive)
    private(set) var processObjects: [AudioObjectID]

    struct Failure: Error { let message: String }

    init(key: String, processObjects: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.key = key
        self.outputUID = outputUID
        self.processObjects = processObjects
        state.targetGain = gain
        state.currentGain = gain
        do {
            try build()
        } catch {
            teardown()
            throw error
        }
    }

    deinit { teardown() }

    func setGain(_ gain: Float) { state.targetGain = gain }

    func configure(gain: Float, balance: Double, mono: Bool) {
        state.targetGain = gain
        // Balance turns down the far side only, so centre leaves both at full.
        state.leftScale = Float(balance > 0 ? 1 - balance : 1)
        state.rightScale = Float(balance < 0 ? 1 + balance : 1)
        state.mono = mono
    }

    var level: Float { state.peakOut }

    var debugLine: String {
        String(
            format: "%@ → %@ gain %.2f in-peak %.3f out-peak %.3f callbacks %d",
            key, outputUID, state.targetGain, state.peakIn, state.peakOut, state.callbacks
        )
    }

    private func build() throws {
        guard #available(macOS 14.2, *) else { throw Failure(message: "Requires macOS 14.2 or later") }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.isExclusive = false

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr, newTap != kAudioObjectUnknown else {
            throw Failure(message: "Could not tap this app's audio (\(tapStatus))")
        }
        tapID = newTap

        guard let tapUID = CA.string(tapID, kAudioTapPropertyUID) else {
            throw Failure(message: "Could not read the tap")
        }

        let aggregateUID = "com.boringnotch.mixer.\(UUID().uuidString)"
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "boringNotchMixer",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 1]
            ]
        ]
        var newAggregate = AudioDeviceID(0)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard aggregateStatus == noErr, newAggregate != 0 else {
            throw Failure(message: "Could not route to that output (\(aggregateStatus))")
        }
        aggregateID = newAggregate

        let state = self.state
        var newProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, queue) {
            _, inInput, _, outOutput, _ in
            Self.render(state: state, input: inInput, output: outOutput)
        }
        guard procStatus == noErr, let proc = newProc else {
            throw Failure(message: "Could not start audio processing (\(procStatus))")
        }
        ioProc = proc

        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else {
            throw Failure(message: "Could not start the output (\(startStatus))")
        }
    }

    func teardown() {
        if aggregateID != 0, let proc = ioProc {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProc = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Copies the tapped audio to the output, scaled, ramping the gain across
    /// the buffer so volume changes never click.
    private static func render(
        state: MixerRenderState,
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        state.callbacks &+= 1

        // The tap is the last input stream; a device's own inputs come first.
        guard let tap = inputs.last, let tapData = tap.mData, tap.mNumberChannels > 0 else { return }
        let tapChannels = Int(tap.mNumberChannels)
        let tapFrames = Int(tap.mDataByteSize) / (MemoryLayout<Float>.size * tapChannels)
        let source = tapData.assumingMemoryBound(to: Float.self)

        let start = state.currentGain
        let end = state.targetGain
        state.currentGain = end

        var peakIn: Float = 0
        var peakOut: Float = 0
        var outputChannelBase = 0
        for buffer in outputs {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            let frames = min(tapFrames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            let destination = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                let gain = frames > 1
                    ? start + (end - start) * Float(frame) / Float(frames - 1)
                    : end
                for channel in 0..<channels {
                    // Stereo in, any number of channels out: the first two
                    // outputs get left/right, the rest stay silent.
                    let outputChannel = outputChannelBase + channel
                    guard outputChannel < 2 else { continue }
                    var sample = source[frame * tapChannels + min(outputChannel, tapChannels - 1)]
                    if state.mono, tapChannels > 1 {
                        sample = (source[frame * tapChannels] + source[frame * tapChannels + 1]) * 0.5
                    }
                    let side = outputChannel == 0 ? state.leftScale : state.rightScale
                    let scaled = max(-1, min(1, sample * gain * side))
                    destination[frame * channels + channel] = scaled
                    peakIn = max(peakIn, abs(sample))
                    peakOut = max(peakOut, abs(scaled))
                }
            }
            outputChannelBase += channels
        }
        state.peakIn = peakIn
        state.peakOut = peakOut
    }
}

// MARK: - Engine

@MainActor
final class AudioMixerEngine: ObservableObject {
    static let shared = AudioMixerEngine()

    @Published private(set) var sources: [MixerSource] = []
    @Published private(set) var devices: [MixerOutputDevice] = []
    @Published private(set) var inputDevices: [MixerOutputDevice] = []
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var defaultInputUID: String?
    @Published private(set) var systemVolume: Double?
    @Published private(set) var systemMuted = false
    @Published private(set) var inputVolume: Double?
    @Published private(set) var inputMuted = false
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var settings: [String: MixerAppSetting] = Defaults[.mixerAppSettings] {
        didSet { updatePolling() }
    }
    @Published private(set) var scenes: [MixerScene] = Defaults[.mixerScenes]
    /// While set, every other app is muted.
    @Published private(set) var solo: String? {
        didSet { updatePolling() }
    }

    private var lastDeviceIDs: [AudioObjectID] = []
    private var sessions: [String: MixerSession] = [:]
    private var meters: [String: MixerMeterSession] = [:]
    private var metersRequested = false
    private var isRunning = false
    private var timer: Timer?
    private var debugTick = 0
    private var enabledObserver: Task<Void, Never>?

    private init() {
        enabledObserver = Task { [weak self] in
            for await enabled in Defaults.updates(.showMixerTab) {
                self?.setRunning(enabled)
            }
        }
    }

    private func setRunning(_ running: Bool) {
        isRunning = running
        updatePolling()
        if !running {
            // Switching the mixer off gives every app its untouched audio back.
            sessions.removeAll()
            meters.removeAll()
            errors.removeAll()
            sources.removeAll()
            lastDeviceIDs = []
            solo = nil
        }
    }

    /// Starts the engine at launch if the mixer is enabled.
    func startIfEnabled() {
        setRunning(Defaults[.showMixerTab])
    }

    /// Level meters only run while the mixer page is on screen.
    func setMetersRequested(_ requested: Bool) {
        metersRequested = requested
        if requested { refresh() } else { meters.removeAll() }
        updatePolling()
    }

    /// Each poll is dozens of calls into coreaudiod, so it only runs while
    /// there is something to keep up to date: the page on screen, or apps
    /// being re-routed (a changed app that starts playing needs its tap).
    private func updatePolling() {
        let wanted = isRunning && (metersRequested || !settings.isEmpty || solo != nil || !sessions.isEmpty)
        if wanted {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            // Asynchronous (the block hops through a Task), so this is safe
            // from inside refresh().
            timer.fire()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// 0...1 peak of an app's audio: after the volume change when the app is
    /// being re-routed, before it (what the app is playing) otherwise.
    func level(for key: String) -> Float {
        if let session = sessions[key] { return session.level }
        return meters[key]?.level ?? 0
    }

    // MARK: App actions

    func setting(for key: String) -> MixerAppSetting { settings[key] ?? MixerAppSetting() }

    func setVolume(_ volume: Double, for key: String) {
        update(key) { $0.volume = min(max(volume, 0), 1.5) }
    }

    func setMuted(_ muted: Bool, for key: String) {
        update(key) { $0.muted = muted }
    }

    func setOutput(_ uid: String?, for key: String) {
        update(key) { $0.outputUID = uid }
    }

    func setBalance(_ balance: Double, for key: String) {
        update(key) { $0.balance = min(max(balance, -1), 1) }
    }

    func setMono(_ mono: Bool, for key: String) {
        update(key) { $0.mono = mono }
    }

    func resetApp(_ key: String) {
        update(key) { $0 = MixerAppSetting() }
    }

    func toggleSolo(_ key: String) {
        solo = solo == key ? nil : key
        for source in sources { apply(source.id) }
    }

    func resetAll() {
        settings = [:]
        Defaults[.mixerAppSettings] = [:]
        solo = nil
        sessions.removeAll()
        errors.removeAll()
    }

    // MARK: Scenes

    func saveScene(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = scenes.firstIndex(where: { $0.name == trimmed }) {
            scenes[index].settings = settings
        } else {
            scenes.append(MixerScene(name: trimmed, settings: settings))
        }
        Defaults[.mixerScenes] = scenes
    }

    func applyScene(_ scene: MixerScene) {
        settings = scene.settings
        Defaults[.mixerAppSettings] = settings
        solo = nil
        for key in Set(sources.map(\.id)).union(sessions.keys) { apply(key) }
    }

    func deleteScene(_ scene: MixerScene) {
        scenes.removeAll { $0.id == scene.id }
        Defaults[.mixerScenes] = scenes
    }

    // MARK: System and microphone

    func setSystemVolume(_ volume: Double) {
        guard let device = defaultOutputDevice() else { return }
        let value = Float32(min(max(volume, 0), 1))
        if CA.setValue(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                       scope: kAudioObjectPropertyScopeOutput, value) {
            systemVolume = Double(value)
        }
    }

    func setSystemMuted(_ muted: Bool) {
        guard let device = defaultOutputDevice() else { return }
        if CA.setValue(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, UInt32(muted ? 1 : 0)) {
            systemMuted = muted
        }
    }

    func setDefaultOutput(_ uid: String) {
        guard let device = devices.first(where: { $0.uid == uid }) else { return }
        if CA.setValue(CA.system, kAudioHardwarePropertyDefaultOutputDevice, device.id) { refresh() }
    }

    func setInputVolume(_ volume: Double) {
        guard let device = defaultInputDevice() else { return }
        let value = Float32(min(max(volume, 0), 1))
        if CA.setValue(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                       scope: kAudioObjectPropertyScopeInput, value) {
            inputVolume = Double(value)
        }
    }

    func setInputMuted(_ muted: Bool) {
        guard let device = defaultInputDevice() else { return }
        if CA.setValue(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput, UInt32(muted ? 1 : 0)) {
            inputMuted = muted
        }
    }

    func setDefaultInput(_ uid: String) {
        guard let device = inputDevices.first(where: { $0.uid == uid }) else { return }
        if CA.setValue(CA.system, kAudioHardwarePropertyDefaultInputDevice, device.id) { refresh() }
    }

    private func update(_ key: String, _ change: (inout MixerAppSetting) -> Void) {
        var setting = self.setting(for: key)
        change(&setting)
        if setting.isUntouched {
            settings[key] = nil
        } else {
            settings[key] = setting
        }
        Defaults[.mixerAppSettings] = settings
        apply(key)
    }

    // MARK: Polling

    private func refresh() {
        // A @Published property announces every assignment, equal or not, and
        // this runs once a second: only write what really changed, so nothing
        // that observes the engine redraws for nothing.
        let outputUID = defaultOutputDevice().flatMap { CA.string($0, kAudioDevicePropertyDeviceUID) }
        if outputUID != defaultOutputUID { defaultOutputUID = outputUID }
        let inputUID = defaultInputDevice().flatMap { CA.string($0, kAudioDevicePropertyDeviceUID) }
        if inputUID != defaultInputUID { defaultInputUID = inputUID }
        // Names, UIDs and stream counts of every device are many Core Audio
        // calls, and the set of devices almost never changes: only re-read it
        // when the list of device IDs does.
        let deviceIDs = CA.objects(CA.system, kAudioHardwarePropertyDevices)
        if deviceIDs != lastDeviceIDs {
            lastDeviceIDs = deviceIDs
            let outputs = readDevices(deviceIDs, scope: kAudioObjectPropertyScopeOutput)
            if outputs != devices { devices = outputs }
            let inputs = readDevices(deviceIDs, scope: kAudioObjectPropertyScopeInput)
            if inputs != inputDevices { inputDevices = inputs }
        }
        readLevelsOfDefaultDevices()

        let found = readSources()
        // Keep an app listed while it still has a session, even between sounds.
        var merged = found
        for (key, session) in sessions where !merged.contains(where: { $0.id == key }) {
            if let kept = sources.first(where: { $0.id == key }), isAlive(session.processObjects) {
                var copy = kept
                copy.isPlaying = false
                merged.append(copy)
            }
        }
        merged.sort { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
        if merged != sources { sources = merged }
        if let solo, !sources.contains(where: { $0.id == solo }) { self.solo = nil }

        for source in sources { apply(source.id) }
        for key in Array(sessions.keys) where !sources.contains(where: { $0.id == key }) {
            sessions[key] = nil
        }
        updateMeters()
        if Defaults[.mixerDebug] { writeDebug() }
        // The last session may just have gone.
        updatePolling()
    }

    private func readLevelsOfDefaultDevices() {
        var volume: Double?
        var muted = false
        if let device = defaultOutputDevice() {
            volume = CA.value(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                              scope: kAudioObjectPropertyScopeOutput, as: Float32.self).map(Double.init)
            muted = (CA.value(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput,
                              as: UInt32.self) ?? 0) != 0
        }
        if volume != systemVolume { systemVolume = volume }
        if muted != systemMuted { systemMuted = muted }

        var micVolume: Double?
        var micMuted = false
        if let device = defaultInputDevice() {
            micVolume = CA.value(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                 scope: kAudioObjectPropertyScopeInput, as: Float32.self).map(Double.init)
            micMuted = (CA.value(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput,
                                 as: UInt32.self) ?? 0) != 0
        }
        if micVolume != inputVolume { inputVolume = micVolume }
        if micMuted != inputMuted { inputMuted = micMuted }
    }

    /// Listen-only taps, for apps that aren't being re-routed (those already
    /// report their own level), and only while the page is showing.
    private func updateMeters() {
        guard metersRequested, Defaults[.mixerShowMeters] else {
            if !meters.isEmpty { meters.removeAll() }
            return
        }
        let wanted = sources.filter { $0.isPlaying && sessions[$0.id] == nil }.prefix(8)
        for key in Array(meters.keys) where !wanted.contains(where: { $0.id == key }) {
            meters[key] = nil
        }
        for source in wanted {
            if let existing = meters[source.id], Set(existing.processObjects) == Set(source.processObjects) { continue }
            meters[source.id] = MixerMeterSession(processObjects: source.processObjects)
        }
    }

    private func isAlive(_ objects: [AudioObjectID]) -> Bool {
        let current = Set(CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList))
        return objects.contains(where: current.contains)
    }

    /// Makes the session for one app match its setting: none when untouched,
    /// otherwise a tap on the right output at the right gain.
    private func apply(_ key: String) {
        let setting = self.setting(for: key)
        guard let source = sources.first(where: { $0.id == key }) else {
            sessions[key] = nil
            return
        }
        let silencedBySolo = solo != nil && solo != key
        if setting.isUntouched && !silencedBySolo {
            if sessions[key] != nil { sessions[key] = nil }
            errors[key] = nil
            return
        }
        guard let outputUID = setting.outputUID ?? defaultOutputUID,
              devices.contains(where: { $0.uid == outputUID }) else {
            sessions[key] = nil
            errors[key] = String(localized: "That output device isn't available")
            return
        }
        let gain = Float(setting.muted || silencedBySolo ? 0 : setting.volume)

        if let session = sessions[key] {
            let sameProcesses = Set(session.processObjects) == Set(source.processObjects)
            if session.outputUID == outputUID && sameProcesses {
                session.configure(gain: gain, balance: setting.balance, mono: setting.mono)
                return
            }
            sessions[key] = nil
        }
        // A listen-only meter on the same app is replaced by the real session.
        meters[key] = nil
        do {
            let session = try MixerSession(
                key: key, processObjects: source.processObjects, outputUID: outputUID, gain: gain
            )
            session.configure(gain: gain, balance: setting.balance, mono: setting.mono)
            sessions[key] = session
            errors[key] = nil
        } catch let failure as MixerSession.Failure {
            errors[key] = failure.message
        } catch {
            errors[key] = error.localizedDescription
        }
    }

    // MARK: Reading the system

    private func defaultOutputDevice() -> AudioObjectID? {
        CA.value(CA.system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
    }

    private func defaultInputDevice() -> AudioObjectID? {
        CA.value(CA.system, kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self)
    }

    private func readDevices(_ deviceIDs: [AudioObjectID], scope: AudioObjectPropertyScope) -> [MixerOutputDevice] {
        deviceIDs.compactMap { device in
            guard !CA.objects(device, kAudioDevicePropertyStreams, scope: scope).isEmpty,
                  let uid = CA.string(device, kAudioDevicePropertyDeviceUID),
                  let name = CA.string(device, kAudioObjectPropertyName),
                  !uid.hasPrefix("com.boringnotch.") else { return nil }
            let transport = CA.value(device, kAudioDevicePropertyTransportType, as: UInt32.self) ?? 0
            return MixerOutputDevice(id: device, uid: uid, name: name, symbol: Self.symbol(for: transport))
        }
    }

    private static func symbol(for transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "speaker.wave.2"
        }
    }

    /// Audio-producing processes, grouped by the app they belong to.
    private func readSources() -> [MixerSource] {
        var groups: [String: MixerSource] = [:]
        for object in CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList) {
            guard let pid = CA.value(object, kAudioProcessPropertyPID, as: pid_t.self), pid != getpid() else { continue }
            let running = (CA.value(object, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0
            guard running else { continue }
            let appPath = Self.outermostAppPath(pid: pid)
            let info = appInfo(path: appPath, fallbackBundleID: CA.string(object, kAudioProcessPropertyBundleID), pid: pid)
            if var existing = groups[info.key] {
                existing.processObjects.append(object)
                groups[info.key] = existing
            } else {
                groups[info.key] = MixerSource(
                    id: info.key, name: info.name, bundlePath: appPath, processObjects: [object], isPlaying: true
                )
            }
        }
        return Array(groups.values)
    }

    /// Opening a Bundle reads its Info.plist from disk; an app's identity and
    /// name don't change while it runs, so ask once per path.
    private var appInfoCache: [String: (key: String, name: String)] = [:]

    private func appInfo(path: String?, fallbackBundleID: String?, pid: pid_t) -> (key: String, name: String) {
        if let path, let cached = appInfoCache[path] { return cached }
        let bundle = path.flatMap { Bundle(path: $0) }
        let key = bundle?.bundleIdentifier ?? path ?? fallbackBundleID ?? "pid-\(pid)"
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? fallbackBundleID
            ?? "pid \(pid)"
        let info = (key: key, name: name)
        if let path { appInfoCache[path] = info }
        return info
    }

    private static func outermostAppPath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
        let components = path.split(separator: "/")
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + components[...index].joined(separator: "/")
    }

    private func writeDebug() {
        debugTick += 1
        let lines = sessions.values.map(\.debugLine).sorted()
        guard !lines.isEmpty || debugTick % 5 == 0 else { return }
        let text = "\(Date()) sessions=\(sessions.count) meters=\(meters.count) solo=\(solo ?? "-") errors=\(errors)\n"
            + lines.map { "  " + $0 }.joined(separator: "\n") + "\n"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mixer-debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: false, encoding: .utf8)
        }
    }
}
