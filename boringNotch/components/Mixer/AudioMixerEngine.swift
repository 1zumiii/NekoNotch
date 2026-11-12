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
    /// Zero-based output channels for left and right: the device's own
    /// speaker pair, which on a multichannel interface need not be 1 and 2.
    var leftChannel = 0
    var rightChannel = 1
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
    /// The output device's object ID when the session was built. The same UID
    /// under a new ID means the device went away and came back (unplugged and
    /// replugged, a Bluetooth reconnect), and the aggregate still points at
    /// the old one.
    let deviceID: AudioObjectID
    let builtAt = Date()
    private let state = MixerRenderState()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "boringnotch.mixer.io", qos: .userInteractive)
    private(set) var processObjects: [AudioObjectID]

    // Watchdog bookkeeping, only touched by the engine on the main actor.
    var checkedCallbacks = 0
    var lastCheck = Date.distantPast
    var stalledChecks = 0

    struct Failure: Error { let message: String }

    init(
        key: String, processObjects: [AudioObjectID], outputUID: String, deviceID: AudioObjectID, gain: Float
    ) throws {
        self.key = key
        self.outputUID = outputUID
        self.deviceID = deviceID
        self.processObjects = processObjects
        state.targetGain = gain
        state.currentGain = gain
        let pair = Self.preferredStereoChannels(of: deviceID)
        state.leftChannel = pair.left
        state.rightChannel = pair.right
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

    /// Advances with every IO cycle, sound or silence, while the session runs.
    var callbacks: Int { state.callbacks }

    /// False once Core Audio reports the aggregate dead, for instance when its
    /// output device disappeared underneath it. An unreadable value counts as
    /// alive; the callback watchdog catches those cases.
    var isAggregateAlive: Bool {
        guard aggregateID != 0 else { return false }
        return (CA.value(aggregateID, kAudioDevicePropertyDeviceIsAlive, as: UInt32.self) ?? 1) != 0
    }

    var debugLine: String {
        String(
            format: "%@ → %@ gain %.2f in-peak %.3f out-peak %.3f callbacks %d",
            key, outputUID, state.targetGain, state.peakIn, state.peakOut, state.callbacks
        )
    }

    /// The speaker pair chosen for the device (Audio MIDI Setup → Configure
    /// Speakers), zero-based. A multichannel interface often has its monitors
    /// on other channels than 1 and 2. Channels 1 and 2 when the device
    /// doesn't say, or names a channel it doesn't have.
    private static func preferredStereoChannels(of device: AudioObjectID) -> (left: Int, right: Int) {
        let fallback = (left: 0, right: 1)
        var address = CA.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput)
        var pair: [UInt32] = [0, 0]
        let expected = UInt32(MemoryLayout<UInt32>.size * 2)
        var size = expected
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &pair) == noErr, size == expected else {
            return fallback
        }
        let count = outputChannelCount(of: device)
        let left = Int(pair[0])
        let right = Int(pair[1])
        guard count >= 2, left != right, (1...count).contains(left), (1...count).contains(right) else {
            return fallback
        }
        return (left: left - 1, right: right - 1)
    }

    private static func outputChannelCount(of device: AudioObjectID) -> Int {
        var address = CA.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              Int(size) >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
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

        // A single-channel output (some USB headsets, a mono speaker) would
        // otherwise only get the left side; give it both, balance applied.
        var totalChannels = 0
        for buffer in outputs { totalChannels += Int(buffer.mNumberChannels) }
        if totalChannels == 1 {
            let rightIndex = min(1, tapChannels - 1)
            for buffer in outputs {
                guard let data = buffer.mData, buffer.mNumberChannels == 1 else { continue }
                let frames = min(tapFrames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                let destination = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    let gain = frames > 1
                        ? start + (end - start) * Float(frame) / Float(frames - 1)
                        : end
                    let left = source[frame * tapChannels]
                    let right = source[frame * tapChannels + rightIndex]
                    let mixed = (left * state.leftScale + right * state.rightScale) * 0.5
                    var scaled = mixed * gain
                    if gain * max(state.leftScale, state.rightScale) > 1 { scaled = softKnee(scaled) }
                    scaled = max(-1, min(1, scaled))
                    destination[frame] = scaled
                    peakIn = max(peakIn, max(abs(left), abs(right)))
                    peakOut = max(peakOut, abs(scaled))
                }
            }
            state.peakIn = peakIn
            state.peakOut = peakOut
            return
        }

        // The device's speaker pair, unless its layout changed under the
        // session and the pair no longer exists.
        var leftChannel = state.leftChannel
        var rightChannel = state.rightChannel
        if leftChannel >= totalChannels || rightChannel >= totalChannels {
            leftChannel = 0
            rightChannel = 1
        }

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
                    // Stereo in, any number of channels out: the speaker pair
                    // gets left/right, the rest stay silent.
                    let outputChannel = outputChannelBase + channel
                    let isLeft = outputChannel == leftChannel
                    guard isLeft || outputChannel == rightChannel else { continue }
                    var sample = source[frame * tapChannels + (isLeft ? 0 : min(1, tapChannels - 1))]
                    if state.mono, tapChannels > 1 {
                        sample = (source[frame * tapChannels] + source[frame * tapChannels + 1]) * 0.5
                    }
                    let side = isLeft ? state.leftScale : state.rightScale
                    // Below unity the input is already within ±1 and this is
                    // the plain product; only a boost bends the peaks.
                    var scaled = sample * gain * side
                    if gain * side > 1 { scaled = softKnee(scaled) }
                    scaled = max(-1, min(1, scaled))
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

    /// Linear up to 0.8, then eases into full scale instead of chopping the
    /// peaks off, so a boosted app gets louder without the hard-clip crackle.
    @inline(__always)
    private static func softKnee(_ x: Float) -> Float {
        let magnitude = abs(x)
        guard magnitude > 0.8 else { return x }
        let shaped = 0.8 + 0.2 * tanhf((magnitude - 0.8) / 0.2)
        return x < 0 ? -shaped : shaped
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
    /// Apps whose chosen output is unavailable right now (unplugged, or not
    /// responding) and which play on the system default until it is back.
    @Published private(set) var fallbackKeys: Set<String> = []
    /// The user turned down "System Audio Recording". Taps would only hear
    /// silence (and mute the app with it), so no app is re-routed meanwhile.
    @Published private(set) var capturePermissionMissing = false

    private var lastDeviceIDs: [AudioObjectID] = []
    private var sessions: [String: MixerSession] = [:]
    private var meters: [String: MixerMeterSession] = [:]
    private var metersRequested = false
    /// Set while the page is on screen, see `refresh`.
    private var keepsOrder = false
    private var isRunning = false
    private var timer: Timer?
    private var debugTick = 0
    private var enabledObserver: Task<Void, Never>?

    /// What a session build depends on. A failed build is only retried early
    /// when one of these changes; otherwise it waits out the back-off.
    private struct BuildInputs: Equatable {
        let outputUID: String
        let processObjects: Set<AudioObjectID>
        let devices: [MixerOutputDevice]
    }

    private struct Retry {
        let inputs: BuildInputs
        let failures: Int
        let notBefore: Date
    }

    private struct Death {
        let outputUID: String
        let at: Date
        let count: Int
    }

    /// Back-off after failed builds, per app.
    private var retries: [String: Retry] = [:]
    /// Sessions the watchdog found dead recently, per app, to tell a one-off
    /// hiccup from a device that keeps failing.
    private var deaths: [String: Death] = [:]
    /// Explicitly chosen outputs that kept dying; apps on them fall back to
    /// the default until the cool-down ends or the device list changes.
    private var unhealthyOutputs: [String: Date] = [:]

    /// A new session needs a moment before its IO starts counting.
    private static let watchdogGrace: TimeInterval = 3
    /// Checks closer together than this say nothing about a stalled IO, so a
    /// burst of refreshes from hardware notifications can't trip it.
    private static let watchdogInterval: TimeInterval = 0.8
    private static let deathWindow: TimeInterval = 60
    private static let unhealthyCoolDown: TimeInterval = 15
    private static let maxBackOff: TimeInterval = 30

    private struct Listener {
        let selector: AudioObjectPropertySelector
        let block: AudioObjectPropertyListenerBlock
    }

    private var listeners: [Listener] = []
    private let listenerQueue = DispatchQueue(label: "boringnotch.mixer.listeners", qos: .utility)
    private var refreshScheduled = false
    /// The device list as last seen by a listener, without the mixer's own
    /// aggregates: building or tearing down a session adds and removes one,
    /// and that must not wake the engine again.
    private var externalDeviceIDs: [AudioObjectID] = []

    /// Listeners on each audio process's "is playing" flag, so a changed app
    /// gets its tap the moment it starts instead of being heard untouched
    /// until the next poll. Keyed by process object, pruned to the current
    /// process list on every read of it.
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    /// This app's own process objects, which are never listened to.
    private var ownProcessObjects: Set<AudioObjectID> = []
    private var processRefreshScheduled = false

    private enum CapturePermission { case granted, denied, notDetermined }
    /// nil until checked after the engine starts.
    private var capturePermission: CapturePermission?
    private var lastPermissionCheck = Date.distantPast

    /// Trailing write of `settings` to UserDefaults; a slider drag changes
    /// them dozens of times a second.
    private var pendingPersist: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    private init() {
        enabledObserver = Task { [weak self] in
            for await enabled in Defaults.updates(.showMixerTab) {
                self?.setRunning(enabled)
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.flushPendingSettings() }
        }
    }

    private func setRunning(_ running: Bool) {
        isRunning = running
        updatePolling()
        if running {
            installListeners()
        } else {
            removeListeners()
            // Switching the mixer off gives every app its untouched audio back.
            sessions.removeAll()
            meters.removeAll()
            errors.removeAll()
            sources.removeAll()
            lastDeviceIDs = []
            solo = nil
            clearRecoveryState()
            flushPendingSettings()
            // Asked again before the first session the next time it starts.
            capturePermission = nil
            lastPermissionCheck = .distantPast
            if capturePermissionMissing { capturePermissionMissing = false }
        }
    }

    /// Forgets fallbacks, back-offs and the watchdog's memory for every app.
    private func clearRecoveryState() {
        if !fallbackKeys.isEmpty { fallbackKeys = [] }
        retries.removeAll()
        deaths.removeAll()
        unhealthyOutputs.removeAll()
    }

    /// The same for one app, when it is reset, left alone or gone.
    private func forgetRecoveryState(for key: String) {
        setFallback(false, for: key)
        retries[key] = nil
        deaths[key] = nil
    }

    private func setFallback(_ on: Bool, for key: String) {
        guard fallbackKeys.contains(key) != on else { return }
        if on { fallbackKeys.insert(key) } else { fallbackKeys.remove(key) }
    }

    /// Starts the engine at launch if the mixer is enabled.
    func startIfEnabled() {
        setRunning(Defaults[.showMixerTab])
    }

    /// Level meters only run while the mixer page is on screen.
    func setMetersRequested(_ requested: Bool) {
        metersRequested = requested
        // Sorted once as the page opens, then held still while it is shown.
        keepsOrder = false
        if requested { refresh() } else { meters.removeAll() }
        keepsOrder = requested
        updatePolling()
    }

    /// Each poll is dozens of calls into coreaudiod, so it only runs while
    /// there is something to keep up to date: the page on screen, or apps
    /// being re-routed (a changed app that starts playing needs its tap).
    private var pollingWanted: Bool {
        isRunning && (metersRequested || !settings.isEmpty || solo != nil || !sessions.isEmpty)
    }

    private func updatePolling() {
        if pollingWanted {
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
            removeProcessListeners()
        }
    }

    // MARK: Hardware notifications

    /// Device plugged or unplugged, default changed, an app started or quit
    /// using audio, coreaudiod restarted: react now instead of on the next
    /// poll, so an unplugged output falls back without a second of silence.
    private static let listenedSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyProcessObjectList,
        kAudioHardwarePropertyServiceRestarted
    ]

    private func installListeners() {
        guard listeners.isEmpty else { return }
        externalDeviceIDs = Self.readExternalDeviceIDs()
        for selector in Self.listenedSelectors {
            var address = CA.address(selector)
            let block = Self.listenerBlock(for: selector, engine: self)
            if AudioObjectAddPropertyListenerBlock(CA.system, &address, listenerQueue, block) == noErr {
                listeners.append(Listener(selector: selector, block: block))
            }
        }
    }

    private func removeListeners() {
        for listener in listeners {
            var address = CA.address(listener.selector)
            AudioObjectRemovePropertyListenerBlock(CA.system, &address, listenerQueue, listener.block)
        }
        listeners.removeAll()
        refreshScheduled = false
        externalDeviceIDs = []
        removeProcessListeners()
    }

    /// Listens to every process in the list that isn't ours and stops
    /// listening to those that left it, while the engine polls anyway.
    private func syncProcessListeners(_ objects: [AudioObjectID]) {
        guard isRunning, pollingWanted else {
            removeProcessListeners()
            return
        }
        let current = Set(objects)
        for (object, block) in processListeners where !current.contains(object) {
            var address = CA.address(kAudioProcessPropertyIsRunningOutput)
            // Fails once the process object is gone, which is the usual case.
            _ = AudioObjectRemovePropertyListenerBlock(object, &address, listenerQueue, block)
            processListeners[object] = nil
        }
        ownProcessObjects.formIntersection(current)
        let ownPID = getpid()
        for object in objects
        where processListeners.index(forKey: object) == nil && !ownProcessObjects.contains(object) {
            // Unreadable means the process already left; the next read prunes it.
            guard let pid = CA.value(object, kAudioProcessPropertyPID, as: pid_t.self) else { continue }
            if pid == ownPID {
                ownProcessObjects.insert(object)
                continue
            }
            var address = CA.address(kAudioProcessPropertyIsRunningOutput)
            let block = Self.processListenerBlock(object: object, engine: self)
            if AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr {
                processListeners[object] = block
            }
        }
    }

    private func removeProcessListeners() {
        for (object, block) in processListeners {
            var address = CA.address(kAudioProcessPropertyIsRunningOutput)
            _ = AudioObjectRemovePropertyListenerBlock(object, &address, listenerQueue, block)
        }
        processListeners.removeAll()
        ownProcessObjects.removeAll()
        processRefreshScheduled = false
    }

    private nonisolated static func processListenerBlock(
        object: AudioObjectID, engine: AudioMixerEngine
    ) -> AudioObjectPropertyListenerBlock {
        { [weak engine] _, _ in
            guard let engine else { return }
            Task { @MainActor in engine.processOutputChanged(object) }
        }
    }

    /// An app started or stopped playing. Starting is what matters now (a
    /// muted app would otherwise be heard until the next poll), so only that
    /// refreshes, without the settling delay the hardware notifications get;
    /// several firing together still make one refresh.
    private func processOutputChanged(_ object: AudioObjectID) {
        guard isRunning, pollingWanted, processListeners.index(forKey: object) != nil else { return }
        guard (CA.value(object, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0 else { return }
        guard !processRefreshScheduled else { return }
        processRefreshScheduled = true
        // Queued behind the other notifications already waiting for the main
        // actor, so a burst is covered by this one refresh.
        Task { @MainActor [weak self] in
            guard let self, self.processRefreshScheduled else { return }
            self.processRefreshScheduled = false
            guard self.isRunning, self.pollingWanted else { return }
            self.refresh()
        }
    }

    /// Built outside the main actor: Core Audio calls the block on its own
    /// queue, so it must not inherit the engine's isolation.
    private nonisolated static func listenerBlock(
        for selector: AudioObjectPropertySelector, engine: AudioMixerEngine
    ) -> AudioObjectPropertyListenerBlock {
        { [weak engine] _, _ in
            guard let engine else { return }
            Task { @MainActor in engine.hardwareChanged(selector) }
        }
    }

    private nonisolated static func readExternalDeviceIDs() -> [AudioObjectID] {
        CA.objects(CA.system, kAudioHardwarePropertyDevices).filter { device in
            !(CA.string(device, kAudioDevicePropertyDeviceUID)?.hasPrefix("com.boringnotch.") ?? false)
        }
    }

    private func hardwareChanged(_ selector: AudioObjectPropertySelector) {
        guard isRunning else { return }
        if selector == kAudioHardwarePropertyServiceRestarted {
            // Every object ID from before the restart is meaningless now.
            sessions.removeAll()
            meters.removeAll()
            lastDeviceIDs = []
            retries.removeAll()
            deaths.removeAll()
            unhealthyOutputs.removeAll()
            externalDeviceIDs = Self.readExternalDeviceIDs()
            // The process objects are gone with the old IDs, and so are the
            // listeners on them; the refresh below listens to the new ones.
            processListeners.removeAll()
            ownProcessObjects.removeAll()
        } else if selector == kAudioHardwarePropertyDevices {
            let current = Self.readExternalDeviceIDs()
            guard current != externalDeviceIDs else { return }
            externalDeviceIDs = current
        } else if selector == kAudioHardwarePropertyProcessObjectList {
            // Listen to a new process straight away, so it is caught even if
            // it starts playing before the refresh below.
            syncProcessListeners(CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList))
        }
        // An idle mixer stays idle; the next poll or page open catches up.
        guard pollingWanted, !refreshScheduled else { return }
        refreshScheduled = true
        // Notifications come in bursts (an unplug changes the device list and
        // the default together); one refresh a moment later covers them all
        // and lets the new default device settle.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self, self.refreshScheduled else { return }
            self.refreshScheduled = false
            guard self.isRunning, self.pollingWanted else { return }
            self.refresh()
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
        // Remember the name too, so the page can still say which device the
        // app is waiting for once it has been unplugged.
        let name = uid.flatMap { wanted in devices.first(where: { $0.uid == wanted })?.name }
        update(key) { setting in
            setting.outputUID = uid
            setting.outputName = name
        }
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
        cancelPendingPersist()
        Defaults[.mixerAppSettings] = [:]
        solo = nil
        sessions.removeAll()
        errors.removeAll()
        clearRecoveryState()
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
        cancelPendingPersist()
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
        schedulePersist()
        apply(key)
    }

    // MARK: Saving settings

    /// `settings` changes at once; the write to UserDefaults waits until the
    /// changes pause, so a drag is saved once instead of dozens of times.
    private func schedulePersist() {
        pendingPersist?.cancel()
        pendingPersist = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.flushPendingSettings()
        }
    }

    /// Writes a waiting change now: at quit and when the engine stops.
    private func flushPendingSettings() {
        guard let pending = pendingPersist else { return }
        pending.cancel()
        pendingPersist = nil
        Defaults[.mixerAppSettings] = settings
    }

    /// For callers that write the whole dictionary themselves right after.
    private func cancelPendingPersist() {
        pendingPersist?.cancel()
        pendingPersist = nil
    }

    // MARK: Capture permission

    /// Opens Privacy & Security → Screen & System Audio Recording.
    func openCapturePermissionSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// False only when the user has definitely turned the permission down.
    /// Process taps need it; without it a tap is still created but hears
    /// silence, and since the tap mutes the app, the app would go quiet with
    /// no explanation. Not asked yet counts as allowed: building the first
    /// tap is what brings up the system prompt.
    ///
    /// A denied or unanswered permission can change at any moment (the
    /// prompt, System Settings), so it is asked again at most once a second;
    /// a granted one every half minute, in case it is revoked.
    private func captureAllowed() -> Bool {
        let now = Date()
        let interval: TimeInterval = capturePermission == .granted ? 30 : 1
        if capturePermission == nil || now.timeIntervalSince(lastPermissionCheck) >= interval {
            lastPermissionCheck = now
            capturePermission = Self.preflightAudioCapture()
        }
        let denied = capturePermission == .denied
        if denied != capturePermissionMissing { capturePermissionMissing = denied }
        if denied {
            // Every app gets its own untouched audio back instead of silence.
            sessions.removeAll()
            meters.removeAll()
        }
        return !denied
    }

    private typealias TCCPreflight = @convention(c) (CFString, CFDictionary?) -> Int32

    /// TCC's own check, which answers without prompting. Resolved at run time
    /// because TCC is a private framework.
    private static let tccPreflight: TCCPreflight? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: TCCPreflight.self)
    }()

    /// 0 granted, 1 denied, anything else not asked yet or unknown. Without
    /// the function this fails open, as the mixer behaved before the check.
    private static func preflightAudioCapture() -> CapturePermission {
        guard let preflight = tccPreflight else { return .granted }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
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
            if outputs != devices {
                devices = outputs
                // A device came or went, or came back under a new ID: give
                // every output a fresh chance.
                unhealthyOutputs.removeAll()
                deaths.removeAll()
            }
            let inputs = readDevices(deviceIDs, scope: kAudioObjectPropertyScopeInput)
            if inputs != inputDevices { inputDevices = inputs }
        }
        readLevelsOfDefaultDevices()
        let now = Date()
        unhealthyOutputs = unhealthyOutputs.filter { now.timeIntervalSince($0.value) < Self.unhealthyCoolDown }

        let processObjects = CA.objects(CA.system, kAudioHardwarePropertyProcessObjectList)
        let found = readSources(processObjects)
        // Keep an app listed while its processes are alive and it still has a
        // session, or is the soloed one, even between sounds: a soloed app has
        // no session of its own, and dropping it the moment it paused would
        // end the solo and unmute everything else.
        let liveObjects = Set(processObjects)
        var kept = Set(sessions.keys)
        if let solo { kept.insert(solo) }
        var merged = found
        for key in kept where !merged.contains(where: { $0.id == key }) {
            guard let previous = sources.first(where: { $0.id == key }) else { continue }
            let objects = sessions[key]?.processObjects ?? previous.processObjects
            guard objects.contains(where: liveObjects.contains) else { continue }
            var copy = previous
            copy.isPlaying = false
            merged.append(copy)
        }
        let byPlayingThenName: (MixerSource, MixerSource) -> Bool = {
            ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased())
        }
        if keepsOrder {
            // The page is on screen: an app that starts or stops playing must
            // not jump to another row under the pointer, least of all the one
            // being dragged. Rows keep their place and new apps go to the end.
            let place = Dictionary(sources.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            let listed = merged.filter { place[$0.id] != nil }.sorted { place[$0.id]! < place[$1.id]! }
            merged = listed + merged.filter { place[$0.id] == nil }.sorted(by: byPlayingThenName)
        } else {
            merged.sort(by: byPlayingThenName)
        }
        if merged != sources { sources = merged }
        if let solo, !sources.contains(where: { $0.id == solo }) { self.solo = nil }

        checkSessionHealth(now: now)
        // Asked before the first session is built, then on the poll while it
        // is missing, so granting it in System Settings takes effect by itself.
        if !sessions.isEmpty || !settings.isEmpty || solo != nil || capturePermissionMissing {
            _ = captureAllowed()
        }
        for source in sources { apply(source.id) }
        for key in Array(sessions.keys) where !sources.contains(where: { $0.id == key }) {
            sessions[key] = nil
        }
        // Apps that are gone take their fallback and back-off with them.
        let current = Set(sources.map(\.id))
        for key in fallbackKeys.union(retries.keys).union(deaths.keys) where !current.contains(key) {
            forgetRecoveryState(for: key)
        }
        updateMeters()
        if Defaults[.mixerDebug] { writeDebug() }
        syncProcessListeners(processObjects)
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
        // A listen-only tap needs the same permission, and would only read silence.
        guard metersRequested, Defaults[.mixerShowMeters], !capturePermissionMissing else {
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

    // MARK: Session health

    /// A healthy session's IO runs continuously, sound or silence. One whose
    /// callback count stopped moving, or whose aggregate Core Audio calls
    /// dead, is dropped here so `apply` builds it again.
    private func checkSessionHealth(now: Date) {
        for (key, session) in sessions where !isHealthy(session, now: now) {
            sessions[key] = nil
            recordDeath(of: session, key: key, now: now)
        }
    }

    private func isHealthy(_ session: MixerSession, now: Date) -> Bool {
        guard session.isAggregateAlive else { return false }
        let count = session.callbacks
        // Not judged until it has had time to start.
        guard now.timeIntervalSince(session.builtAt) >= Self.watchdogGrace else {
            session.checkedCallbacks = count
            session.lastCheck = now
            return true
        }
        guard now.timeIntervalSince(session.lastCheck) >= Self.watchdogInterval else { return true }
        session.stalledChecks = count == session.checkedCallbacks ? session.stalledChecks + 1 : 0
        session.checkedCallbacks = count
        session.lastCheck = now
        return session.stalledChecks < 2
    }

    /// The first death is rebuilt straight away. Dying again soon after means
    /// the device itself is the problem: an explicitly chosen output is set
    /// aside so the app falls back to the default, and the default (which has
    /// nothing to fall back to) is retried with a growing delay, so a broken
    /// device can never glitch the audio every second.
    private func recordDeath(of session: MixerSession, key: String, now: Date) {
        let uid = session.outputUID
        var count = 1
        if let last = deaths[key], last.outputUID == uid, now.timeIntervalSince(last.at) < Self.deathWindow {
            count = last.count + 1
        }
        deaths[key] = Death(outputUID: uid, at: now, count: count)
        guard count >= 2 else { return }
        if setting(for: key).outputUID == uid, uid != defaultOutputUID {
            unhealthyOutputs[uid] = now
        } else {
            let inputs = BuildInputs(
                outputUID: uid, processObjects: Set(session.processObjects), devices: devices
            )
            retries[key] = Retry(inputs: inputs, failures: count - 1, notBefore: now + Self.backOff(count - 1))
        }
    }

    /// 1 s, 2 s, 4 s … up to the cap.
    private static func backOff(_ failures: Int) -> TimeInterval {
        min(maxBackOff, pow(2, Double(max(failures, 1) - 1)))
    }

    /// Makes the session for one app match its setting: none when untouched,
    /// otherwise a tap on the right output at the right gain.
    private func apply(_ key: String) {
        var setting = self.setting(for: key)
        guard let source = sources.first(where: { $0.id == key }) else {
            sessions[key] = nil
            forgetRecoveryState(for: key)
            return
        }
        let silencedBySolo = solo != nil && solo != key
        if setting.isUntouched && !silencedBySolo {
            if sessions[key] != nil { sessions[key] = nil }
            if errors[key] != nil { errors[key] = nil }
            forgetRecoveryState(for: key)
            return
        }

        // A chosen output that is unplugged or keeps failing falls back to the
        // default; the preference stays, so the app moves back on its own
        // (through the output check below) once the device returns.
        var target: MixerOutputDevice?
        if let wanted = setting.outputUID,
           unhealthyOutputs[wanted] == nil,
           let device = devices.first(where: { $0.uid == wanted }) {
            target = device
            // Settings saved before names were remembered pick theirs up here.
            if setting.outputName == nil {
                setting.outputName = device.name
                settings[key] = setting
                schedulePersist()
            }
        } else if let fallback = defaultOutputUID {
            target = devices.first(where: { $0.uid == fallback })
        }
        guard let target else {
            sessions[key] = nil
            setFallback(false, for: key)
            let message = String(localized: "That output device isn't available")
            if errors[key] != message { errors[key] = message }
            return
        }
        setFallback(setting.outputUID != nil && setting.outputUID != target.uid, for: key)
        let gain = Float(setting.muted || silencedBySolo ? 0 : setting.volume)

        if let session = sessions[key] {
            let sameProcesses = Set(session.processObjects) == Set(source.processObjects)
            if session.outputUID == target.uid && session.deviceID == target.id && sameProcesses {
                session.configure(gain: gain, balance: setting.balance, mono: setting.mono)
                return
            }
            sessions[key] = nil
        }

        // Without the permission the app keeps playing as it is; the page
        // explains why, so this is not an error of the app's own.
        guard captureAllowed() else { return }

        // After a failed build, wait out the back-off unless something the
        // build depends on has changed since.
        let inputs = BuildInputs(
            outputUID: target.uid, processObjects: Set(source.processObjects), devices: devices
        )
        if let retry = retries[key] {
            if retry.inputs != inputs {
                retries[key] = nil
            } else if Date() < retry.notBefore {
                return
            }
        }

        // A listen-only meter on the same app is replaced by the real session.
        meters[key] = nil
        do {
            let session = try MixerSession(
                key: key, processObjects: source.processObjects, outputUID: target.uid,
                deviceID: target.id, gain: gain
            )
            session.configure(gain: gain, balance: setting.balance, mono: setting.mono)
            sessions[key] = session
            retries[key] = nil
            if errors[key] != nil { errors[key] = nil }
        } catch {
            let failures = (retries[key]?.failures ?? 0) + 1
            retries[key] = Retry(
                inputs: inputs, failures: failures, notBefore: Date() + Self.backOff(failures)
            )
            errors[key] = (error as? MixerSession.Failure)?.message ?? error.localizedDescription
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
    private func readSources(_ processObjects: [AudioObjectID]) -> [MixerSource] {
        var groups: [String: MixerSource] = [:]
        for object in processObjects {
            guard let pid = CA.value(object, kAudioProcessPropertyPID, as: pid_t.self), pid != getpid() else { continue }
            let running = (CA.value(object, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) ?? 0) != 0
            guard running else { continue }
            let executable = Self.executablePath(pid: pid)
            let appPath = executable.flatMap(Self.outermostAppPath(executable:))
            // Core Audio reports an empty string, not nothing, for a process
            // without a bundle ID.
            let bundleID = CA.string(object, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
            let info = appInfo(path: appPath, fallbackBundleID: bundleID, executable: executable, pid: pid)
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

    private func appInfo(
        path: String?, fallbackBundleID: String?, executable: String?, pid: pid_t
    ) -> (key: String, name: String) {
        guard let path else {
            // Not inside an app (a command-line player, a helper daemon): key
            // it by something that survives a relaunch, so a setting saved
            // for it still applies next time, and only fall back to the pid
            // when nothing else is known.
            let executableName = executable.map { URL(fileURLWithPath: $0).lastPathComponent }
            let key = fallbackBundleID ?? executable ?? "pid-\(pid)"
            let name = executableName ?? fallbackBundleID ?? "pid \(pid)"
            return (key: key, name: name)
        }
        if let cached = appInfoCache[path] { return cached }
        let bundle = Bundle(path: path)
        let key = bundle?.bundleIdentifier ?? path
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let info = (key: key, name: name)
        appInfoCache[path] = info
        return info
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
        return path.isEmpty ? nil : path
    }

    private static func outermostAppPath(executable path: String) -> String? {
        let components = path.split(separator: "/")
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + components[...index].joined(separator: "/")
    }

    private func writeDebug() {
        debugTick += 1
        let lines = sessions.values.map(\.debugLine).sorted()
        guard !lines.isEmpty || debugTick % 5 == 0 else { return }
        let text = "\(Date()) sessions=\(sessions.count) meters=\(meters.count) solo=\(solo ?? "-") errors=\(errors)"
            + " fallback=\(fallbackKeys.sorted()) unhealthy=\(unhealthyOutputs.keys.sorted())"
            + " backoff=\(retries.mapValues(\.failures))\n"
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
