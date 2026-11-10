//
//  BoringNotchSkyLightWindow.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import SkyLightWindow
import Defaults
import Combine

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32

        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        guard let SLSRemoveWindowsFromSpaces = unsafeBitCast(
            dlsym(handler, "SLSRemoveWindowsFromSpaces"),
            to: F_SLSRemoveWindowsFromSpaces?.self
        ) else {
            return
        }

        // Remove the window from the SkyLight space
        _ = SLSRemoveWindowsFromSpaces(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

class BoringNotchSkyLightWindow: NSPanel {
    private var isSkyLightEnabled: Bool = false

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )

        configureWindow()
        setupObservers()
    }

    private func configureWindow() {
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = Self.baseLevel
        hasShadow = false
        isReleasedWhenClosed = false

        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)

        updateCollectionBehavior()

        // Apply initial sharing type setting
        updateSharingType()
    }

    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)

        Defaults.publisher(.hideNonNotchedFromMissionControl)
            .sink { [weak self] _ in
                self?.updateCollectionBehavior()
            }
            .store(in: &observers)

        NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification, object: self)
            .sink { [weak self] _ in
                self?.updateCollectionBehavior()
                self?.updateLevel()
            }
            .store(in: &observers)

        FullscreenMediaDetector.shared.$fullscreenScreens
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateLevel()
            }
            .store(in: &observers)

        // An app coming to the front is when a game's window usually goes
        // over the notch; it may settle its level a moment later.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification))
            .sink { [weak self] _ in
                self?.updateLevel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.updateLevel()
                }
            }
            .store(in: &observers)

        // A game already in front can go full screen, or raise its window on
        // a click, with no notification at all, hence the slow poll.
        Timer.publish(every: 2, tolerance: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateLevel()
            }
            .store(in: &observers)

        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: self)
            .sink { [weak self] _ in
                self?.cleanupObservers()
            }
            .store(in: &observers)
    }

    private func updateCollectionBehavior() {
        var newBehavior: NSWindow.CollectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        let hasNotch = (self.screen?.safeAreaInsets.top ?? 0) > 0

        if Defaults[.hideNonNotchedFromMissionControl] && !hasNotch {
            newBehavior.insert(.transient)
        }

        collectionBehavior = newBehavior
    }

    private static let baseLevel: NSWindow.Level = .mainMenu + 3

    /// Games put their full-screen window above the menu bar, and how far
    /// above differs: Wine and CrossOver use the very level the notch has, so
    /// the notch showed until the first click brought the game in front of
    /// it; others go up to the shielding level. Neither needs a full-screen
    /// space, so there is nothing to detect but the window itself: when the
    /// frontmost app has one over the notch at our level or higher, the notch
    /// goes one above it, and comes back down when that is no longer so.
    private func updateLevel() {
        var target = Self.baseLevel.rawValue

        if let uuid = screen?.displayUUID,
           FullscreenMediaDetector.shared.fullscreenScreens.contains(uuid) {
            target = Int(CGShieldingWindowLevel()) + 1
        }
        let covering = coveringLayerOfFrontmostApp()
        if let covering {
            target = max(target, covering + 1)
        }
        if let uuid = screen?.displayUUID {
            FullscreenMediaDetector.shared.setCovered(
                uuid,
                covered: covering != nil,
                bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            )
        }

        if level.rawValue != target {
            level = NSWindow.Level(rawValue: target)
        }
    }

    /// The highest layer, at or above the notch's usual one, of a window of
    /// the frontmost app that lies over the notch. Nil if there is none.
    private func coveringLayerOfFrontmostApp() -> Int? {
        guard isVisible,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]]
        else { return nil }

        func bounds(_ info: [String: Any]) -> CGRect? {
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dict)
        }

        // Our own entry gives the notch's place in the list's coordinates.
        guard let own = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == windowNumber }),
              let ownBounds = bounds(own)
        else { return nil }
        // Inside the menu bar, so a menu hanging from it does not count.
        let notchPoint = CGPoint(x: ownBounds.midX, y: ownBounds.minY + 5)
        // Above this are the system's own indicators; nothing to outrank.
        let ceiling = Int(CGShieldingWindowLevel())

        var highest: Int?
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int).map({ $0 == Int(front.processIdentifier) }) == true,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer >= Self.baseLevel.rawValue, layer <= ceiling,
                  bounds(info)?.contains(notchPoint) == true
            else { continue }
            highest = max(highest ?? layer, layer)
        }
        return highest
    }

    private func updateSharingType() {
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readWrite
        }
    }

    func enableSkyLight() {
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
        }
    }

    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
    }

    private var observers: Set<AnyCancellable> = []

    private func cleanupObservers() {
        Task { @MainActor in
            self.observers.forEach { $0.cancel() }
            self.observers.removeAll()
        }
    }

    /// False by default so a click on the notch never activates the app or
    /// steals focus from whatever is frontmost — load-bearing for every
    /// normal interaction (hover-to-open, music controls, OSD). A text field
    /// needs this flipped on for the moment it's actually being typed into,
    /// and back off the instant it isn't — never left permanently true.
    ///
    /// This is the window class actually instantiated for the notch
    /// (createBoringNotchWindow uses BoringNotchSkyLightWindow, not the
    /// separate, unused BoringNotchWindow class) — an earlier fix targeted
    /// that unused class and silently did nothing.
    var wantsKeyForTextInput = false {
        didSet {
            guard wantsKeyForTextInput != oldValue else { return }
            if wantsKeyForTextInput {
                makeKey()
            }
        }
    }

    override var canBecomeKey: Bool { wantsKeyForTextInput }
    override var canBecomeMain: Bool { false }
}
