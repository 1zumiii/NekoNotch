//
//  MixerModels.swift
//  boringNotch
//
//  Per-app volume and output routing, in the spirit of SoundSource.
//
import AppKit
import CoreAudio
import Defaults

/// What the user chose for one app. The defaults mean "leave it alone".
struct MixerAppSetting: Codable, Defaults.Serializable, Equatable {
    /// 1 = unchanged. Above 1 boosts, with a hard limit at full scale.
    var volume: Double = 1
    var muted: Bool = false
    /// nil follows the system's default output device.
    var outputUID: String?
    /// -1 is all left, 1 is all right.
    var balance: Double = 0
    var mono: Bool = false

    init() {}

    // Settings saved by earlier builds have no balance/mono; decode them as defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        outputUID = try container.decodeIfPresent(String.self, forKey: .outputUID)
        balance = try container.decodeIfPresent(Double.self, forKey: .balance) ?? 0
        mono = try container.decodeIfPresent(Bool.self, forKey: .mono) ?? false
    }

    /// True when the app can be left completely untouched (no tap at all).
    var isUntouched: Bool {
        abs(volume - 1) < 0.005 && !muted && outputUID == nil && abs(balance) < 0.01 && !mono
    }
}

/// A saved set of per-app settings that can be applied in one go.
struct MixerScene: Codable, Defaults.Serializable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var settings: [String: MixerAppSetting]
}

extension Defaults.Keys {
    static let showMixerTab = Key<Bool>("showMixerTab", default: false)
    static let mixerAppSettings = Key<[String: MixerAppSetting]>("mixerAppSettings", default: [:])
    static let mixerScenes = Key<[MixerScene]>("mixerScenes", default: [])
    /// Level meters need a listen-only tap on each playing app.
    static let mixerShowMeters = Key<Bool>("mixerShowMeters", default: true)
    /// Writes a line per active session to the app's temporary folder.
    static let mixerDebug = Key<Bool>("mixerDebug", default: false)
}

/// An app (all of its audio processes grouped) that is, or recently was, making sound.
struct MixerSource: Identifiable, Equatable {
    /// Bundle identifier of the outermost app, or its path when it has none.
    let id: String
    var name: String
    var bundlePath: String?
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
}

struct MixerOutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let symbol: String
}
