//
//  MediaKeys.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import Defaults

// Media playback and the media controller.
extension Defaults.Keys {
    static let coloredSpectrogram = Key<Bool>("coloredSpectrogram", default: true)
    static let realtimeAudioWaveform = Key<Bool>("realtimeAudioWaveform", default: true)

    /// Every bar of the closed-notch waveform gets its own hue, slowly rotating.
    static let rainbowWaveform = Key<Bool>("rainbowWaveform", default: true)

    /// Multiplier on how fast the rainbow hues rotate (1 = one full turn in 12 s).
    static let rainbowWaveformSpeed = Key<Double>("rainbowWaveformSpeed", default: 1.0)
    static let enableSneakPeek = Key<Bool>("enableSneakPeek", default: true)
    static let sneakPeekStyles = Key<SneakPeekStyle>("sneakPeekStyles", default: .standard)
    static let waitInterval = Key<Double>("waitInterval", default: 3)
    static let showShuffleAndRepeat = Key<Bool>("showShuffleAndRepeat", default: false)
    static let enableLyrics = Key<Bool>("enableLyrics", default: false)
    static let showRemainingTime = Key<Bool>("showRemainingTime", default: false)
    static let showMediaSourceAppIcon = Key<Bool>("showMediaSourceAppIcon", default: true)
    static let musicControlSlots = Key<[MusicControlButton]>(
        "musicControlSlots",
        default: MusicControlButton.defaultLayout
    )
    static let musicControlSlotLimit = Key<Int>(
        "musicControlSlotLimit",
        default: MusicControlButton.defaultLayout.count
    )
    static let mediaController = Key<MediaControllerType>("mediaController", default: defaultMediaController)
    static let didChooseMediaController = Key<Bool>("didChooseMediaController", default: false)
    static let didMigrateMediaControllerChoice = Key<Bool>("didMigrateMediaControllerChoice", default: false)
    static let lastSupportedNowPlayingBundleIdentifier = Key<String?>(
        "lastSupportedNowPlayingBundleIdentifier",
        default: nil
    )

    // Keep the default stable. Runtime availability is handled by MusicManager.
    static var defaultMediaController: MediaControllerType {
        .nowPlaying
    }
    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)
}
