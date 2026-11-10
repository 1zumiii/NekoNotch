//
//  FullscreenMediaDetection.swift
//  boringNotch
//
//  Created by Richard Kunkli on 06/09/2024.
//

import Foundation
import Combine
import Defaults
import MacroVisionKit

@MainActor
final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()

    @Published var fullscreenStatus: [String: Bool] = [:]
    /// Screens whose current space is a full-screen one, whatever the
    /// hide-notch setting says. The notch window raises its level from this.
    @Published var fullscreenScreens: Set<String> = []
    /// Screens where the frontmost app has a window over the notch without a
    /// full-screen space, as games under Wine and CrossOver do. They count as
    /// full screen for hiding; the notch window reports them.
    @Published private(set) var coveredScreens: Set<String> = []

    /// Whether the notch is hidden for a full-screen app on any screen.
    var hidesNotchOnAnyScreen: Bool {
        Defaults[.hideNotchOption] != .never
            && (fullscreenStatus.values.contains(true) || !coveredScreens.isEmpty)
    }

    func setCovered(_ uuid: String, covered: Bool, bundleID: String?) {
        var counts = covered
        if counts, Defaults[.hideNotchOption] == .nowPlayingOnly {
            counts = bundleID != nil && bundleID == MusicManager.shared.bundleIdentifier
        }
        if counts {
            if !coveredScreens.contains(uuid) { coveredScreens.insert(uuid) }
        } else if coveredScreens.contains(uuid) {
            coveredScreens.remove(uuid)
        }
    }

    private var monitorTask: Task<Void, Never>?

    private init() {
        startMonitoring()
    }

    deinit {
        monitorTask?.cancel()
    }

    private func startMonitoring() {
        monitorTask = Task { @MainActor in
            let stream = await FullScreenMonitor.shared.spaceChanges()
            for await spaces in stream {
                updateStatus(with: spaces)
            }
        }
    }

    private func updateStatus(with spaces: [MacroVisionKit.FullScreenMonitor.SpaceInfo]) {
        var newStatus: [String: Bool] = [:]

        for space in spaces {
            if let uuid = space.screenUUID {
                let shouldDetect: Bool
                if Defaults[.hideNotchOption] == .nowPlayingOnly, let musicSourceBundle = MusicManager.shared.bundleIdentifier {
                    shouldDetect = space.runningApps.contains(musicSourceBundle)
                } else {
                    shouldDetect = true
                }
                newStatus[uuid] = shouldDetect
            }
        }

        self.fullscreenStatus = newStatus
        self.fullscreenScreens = Set(spaces.compactMap(\.screenUUID))
    }
}
