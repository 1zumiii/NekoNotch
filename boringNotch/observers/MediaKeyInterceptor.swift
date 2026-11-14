//
//  MediaKeyInterceptor.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-23.

import Foundation
import AppKit
import ApplicationServices
import Defaults
import AVFoundation

private let kSystemDefinedEventType = CGEventType(rawValue: 14)!

/// The tap runs on a thread of its own, not the main thread: an active tap
/// holds up every input event behind the one it is handling, so a busy main
/// thread used to stall clicks and keys all over the system. The tap only
/// decides whether to swallow an event; what a key does runs on the main
/// thread afterwards.
final class MediaKeyInterceptor: @unchecked Sendable {
    static let shared = MediaKeyInterceptor()

    private enum NXKeyType: Int {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
        case keyboardBrightnessUp = 21
        case keyboardBrightnessDown = 22
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The run loop of the tap's own thread, to stop it again.
    private var tapRunLoop: CFRunLoop?
    private let step: Float = 1.0 / 16.0
    private var audioPlayer: AVAudioPlayer?

    private init() {}

    private var isTapActive: Bool {
        eventTap != nil && runLoopSource != nil
    }

    // MARK: - Accessibility (via XPC)

    func requestAccessibilityAuthorization() {
        XPCHelperClient.shared.requestAccessibilityAuthorization()
    }

    func ensureAccessibilityAuthorization(promptIfNeeded: Bool = false) async -> Bool {
        await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: promptIfNeeded)
    }

    // MARK: - Event Tap

    func start(promptIfNeeded: Bool = false) async {
        // A test host must not hold up the system's input: the tests may run
        // in several hosts at once, and each would add an active tap.
        guard !isRunningTests else { return }
        // Ensure OSD replacement is enabled
        guard Defaults[.osdReplacement] else {
            stop()
            return
        }

        // Only require Accessibility if any selected source uses the built-in controls
        let needsAccessibility = Defaults[.osdBrightnessSource] == .builtin || Defaults[.osdVolumeSource] == .builtin
        if needsAccessibility {
            let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
            if !authorized {
                if promptIfNeeded {
                    let granted = await ensureAccessibilityAuthorization(promptIfNeeded: true)
                    guard granted else { return }
                } else {
                    return
                }
            }
        }

        if let eventTap, isTapActive {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return
        }

        if eventTap != nil || runLoopSource != nil {
            stop()
        }

        let mask = CGEventMask(1 << kSystemDefinedEventType.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, userInfo in
                guard let userInfo else { return Unmanaged.passRetained(cgEvent) }
                let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    // Back on through the main thread: while that is stuck the
                    // tap stays off and events go straight past it.
                    DispatchQueue.main.async {
                        guard AXIsProcessTrusted() else {
                            interceptor.stop()
                            return
                        }
                        interceptor.reenableEventTap(after: type)
                    }
                    return nil
                }

                return interceptor.handleEvent(cgEvent)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        if let eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            if let runLoopSource {
                tapRunLoop = Self.startTapThread(with: runLoopSource)
            }
            CGEvent.tapEnable(tap: eventTap, enable: true)
        } else {
            Log.osd.error("⚠️ [MediaKeyInterceptor] Failed to create media-key event tap")
        }
    }

    /// A thread that does nothing but run the tap, at the priority of input.
    /// Returns once its run loop holds the tap's source.
    private static func startTapThread(with source: CFRunLoopSource) -> CFRunLoop {
        var runLoop: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "MediaKeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return runLoop!
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource, let tapRunLoop {
            CFRunLoopRemoveSource(tapRunLoop, runLoopSource, .commonModes)
            CFRunLoopStop(tapRunLoop)
        }

        runLoopSource = nil
        tapRunLoop = nil
        eventTap = nil
    }

    private func reenableEventTap(after type: CGEventType) {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)

        let reason: String
        switch type {
        case .tapDisabledByTimeout:
            reason = "timeout"
        case .tapDisabledByUserInput:
            reason = "user input"
        default:
            reason = "unknown reason"
        }

        Log.osd.debug("ℹ️ [MediaKeyInterceptor] Re-enabled media-key event tap after \(reason)")
    }

    // MARK: - Event Handling

    private func handleEvent(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // Ensure the CGEvent has a valid type before converting to NSEvent
        guard cgEvent.type != .null else {
            return Unmanaged.passUnretained(cgEvent)
        }

        guard let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let stateByte = ((data1 & 0xFF00) >> 8)

        // 0xA = key down, 0xB = key up. Only handle key down.
        guard stateByte == 0xA,
              let keyType = NXKeyType(rawValue: keyCode) else {
            return Unmanaged.passUnretained(cgEvent)
        }

        // Determine which source is selected for this control (brightness/volume/keyboard)
        let selectedSource: OSDControlSource = {
            switch keyType {
            case .soundUp, .soundDown, .mute:
                return Defaults[.osdVolumeSource]
            case .brightnessUp, .brightnessDown:
                return Defaults[.osdBrightnessSource]
            case .keyboardBrightnessUp, .keyboardBrightnessDown:
                return .builtin
            }
        }()

        let flags = nsEvent.modifierFlags
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)

        // If an external source is selected and available, allow the event to pass through (external app will emit OSD notifications)
        switch selectedSource {
        case .betterDisplay:
            if BetterDisplayManager.shared.isBetterDisplayAvailable {
                if (keyType == .brightnessUp || keyType == .brightnessDown) && command {
                    break
                }
                return Unmanaged.passUnretained(cgEvent)
            }
        case .lunar:
            if LunarManager.shared.isLunarAvailable {
                if (keyType == .brightnessUp || keyType == .brightnessDown) && command {
                    break
                }
                return Unmanaged.passUnretained(cgEvent)
            }
        case .builtin:
            break
        }

        // Swallowed here, acted on by the main thread without waiting for it.
        DispatchQueue.main.async {
            // Option (without shift) has its own action.
            if option && !shift, self.handleOptionAction(for: keyType, command: command) {
                return
            }
            self.handleKeyPress(keyType: keyType, option: option, shift: shift, command: command)
        }
        return nil
    }

    private func handleOptionAction(for keyType: NXKeyType, command: Bool) -> Bool {
        let action = Defaults[.optionKeyAction]

        switch action {
        case .openSettings:
            openSystemSettings(for: keyType, command: command)
            return true
        case .showOSD:
            showOSD(for: keyType, command: command)
            return true
        case .none:
            return true
        }
    }

    private func prepareAudioPlayerIfNeeded() {
        guard audioPlayer == nil else { return }

        let defaultPath = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        if FileManager.default.fileExists(atPath: defaultPath) {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: defaultPath))
                Log.osd.debug("🔊 [MediaKeyInterceptor] Loaded default Bezel audio from: \(defaultPath)")
            } catch {
                Log.osd.error("⚠️ [MediaKeyInterceptor] Failed to init AVAudioPlayer with default path \(defaultPath): \(error.localizedDescription)")
            }
        } else {
            Log.osd.error("⚠️ [MediaKeyInterceptor] Default bezel audio not found at: \(defaultPath)")
        }

        if let player = audioPlayer {
            player.volume = 1.0
            player.numberOfLoops = 0
            player.prepareToPlay()
        }
    }

    private func playFeedbackSound() {
        // Single-key lookup — persistentDomain(forName:) materialized the
        // entire NSGlobalDomain on every volume key press.
        let feedback = CFPreferencesCopyAppValue(
            "com.apple.sound.beep.feedback" as CFString,
            kCFPreferencesAnyApplication
        ) as? Int
        guard feedback == 1 else { return }

        prepareAudioPlayerIfNeeded()
        guard let player = audioPlayer else {
            Log.osd.error("⚠️ [MediaKeyInterceptor] No audio player available to play feedback sound")
            return
        }
        if let url = player.url {
            Log.osd.debug("🔊 [MediaKeyInterceptor] Playing feedback sound from: \(url.path)")
        } else {
            Log.osd.debug("🔊 [MediaKeyInterceptor] Playing feedback sound (no url available for AVAudioPlayer)")
        }
        if player.isPlaying {
            player.stop()
            player.currentTime = 0
        }
        player.play()
    }

    private func handleKeyPress(keyType: NXKeyType, option: Bool, shift: Bool, command: Bool) {
        let stepDivisor: Float = (option && shift) ? 4.0 : 1.0

        switch keyType {
        case .soundUp:
            Task { @MainActor in
                self.playFeedbackSound()
                VolumeManager.shared.increase(stepDivisor: stepDivisor)
            }
        case .soundDown:
            Task { @MainActor in
                self.playFeedbackSound()
                VolumeManager.shared.decrease(stepDivisor: stepDivisor)
            }
        case .mute:
            Task { @MainActor in
                VolumeManager.shared.toggleMuteAction()
            }
        case .brightnessUp, .keyboardBrightnessUp:
            let delta = step / stepDivisor
            adjustBrightness(delta: delta, keyboard: keyType == .keyboardBrightnessUp || command)
        case .brightnessDown, .keyboardBrightnessDown:
            let delta = -(step / stepDivisor)
            adjustBrightness(delta: delta, keyboard: keyType == .keyboardBrightnessDown || command)
        }
    }

    private func adjustBrightness(delta: Float, keyboard: Bool) {
        Task { @MainActor in
            if keyboard {
                KeyboardBacklightManager.shared.setRelative(delta: delta)
            } else {
                BrightnessManager.shared.setRelative(delta: delta)
            }
        }
    }

    private func showOSD(for keyType: NXKeyType, command: Bool) {
        Task { @MainActor in
            switch keyType {
            case .soundUp, .soundDown, .mute:
                let v = VolumeManager.shared.rawVolume
                BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(v))
            case .brightnessUp, .brightnessDown:
                if command {
                    let v = KeyboardBacklightManager.shared.rawBrightness
                    BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(v))
                } else {
                    let v = BrightnessManager.shared.rawBrightness
                    let target = await BrightnessManager.shared.brightnessTargetUUID()
                    BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .brightness, value: CGFloat(v), targetScreenUUID: target)
                }
            case .keyboardBrightnessUp, .keyboardBrightnessDown:
                let v = KeyboardBacklightManager.shared.rawBrightness
                BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(v))
            }
        }
    }

    private func openSystemSettings(for keyType: NXKeyType, command: Bool) {
        let urlString: String

        switch keyType {
        case .soundUp, .soundDown, .mute:
            urlString = "x-apple.systempreferences:com.apple.preference.sound"
        case .brightnessUp, .brightnessDown:
            if command {
                urlString = "x-apple.systempreferences:com.apple.preference.keyboard"
            } else {
                urlString = "x-apple.systempreferences:com.apple.preference.displays"
            }
        case .keyboardBrightnessUp, .keyboardBrightnessDown:
            urlString = "x-apple.systempreferences:com.apple.preference.keyboard"
        }

        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
