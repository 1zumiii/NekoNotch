//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 10. 17..
//

import SwiftUI
import Defaults

// MARK: - File System Paths
let documentsDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    ?? URL(fileURLWithPath: NSTemporaryDirectory())
let bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.github.1zumiii.nekonotch"
let appVersion = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))"

let temporaryDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    ?? URL(fileURLWithPath: NSTemporaryDirectory())
let spacing: CGFloat = 16

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}

enum HideNotchOption: String, Defaults.Serializable {
    case always
    case nowPlayingOnly
    case never
}

struct AppLanguage: RawRepresentable, Hashable, Identifiable, Defaults.Serializable {
    static let system = AppLanguage(rawValue: "system")

    var id: String { rawValue }
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The languages the whole interface is translated into. Others were
    /// only partly translated and showed a mix with English, so they were
    /// dropped; a system in another language gets English.
    static let supported = ["en", "zh-Hans"]

    static var allCases: [AppLanguage] {
        let languages = supported
            .filter(isSelectableLocalization)
            .map(AppLanguage.init(rawValue:))
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        return [.system] + languages
    }

    /// A language picked before the others were dropped goes back to the
    /// system's, with its override removed.
    static func migrateUnsupportedChoice() {
        let current = Defaults[.appLanguage]
        guard current != .system, !supported.contains(current.rawValue) else { return }
        Defaults[.appLanguage] = .system
        AppLanguage.system.applyAppleLanguagesOverride()
    }

    var displayName: String {
        if self == .system {
            return NSLocalizedString(
                "System default",
                comment: "Language picker option: follow the system app language"
            )
        }

        let displayName = nativeLocale.localizedString(forIdentifier: rawValue) ?? rawValue
        return displayName.capitalized(with: nativeLocale)
    }

    private var nativeLocale: Locale {
        Locale(identifier: rawValue)
    }

    private static func isSelectableLocalization(_ identifier: String) -> Bool {
        guard identifier != "Base" else { return false }
        guard let url = Bundle.main.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: identifier
        ) else {
            return false
        }

        guard
            let data = try? Data(contentsOf: url),
            let strings = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: String]
        else {
            return false
        }

        return strings.values.contains { !$0.isEmpty }
    }

    func applyAppleLanguagesOverride() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}

enum DisplayMode: String, Codable, CaseIterable, Identifiable, Defaults.Serializable {
    case preferredDisplay
    case fallbackIfPreferredUnavailable
    case activeDisplay
    case allDisplays

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .preferredDisplay:
            "Use preferred display"
        case .fallbackIfPreferredUnavailable:
            "Automatically switch display if preferred is unavailable"
        case .activeDisplay:
            "Always follow active display"
        case .allDisplays:
            "Show on all displays"
        }
    }
}

// macOS 27 renamed the "Accessibility" privacy pane to "Device Control and
// Data Access". Read the name from Apple's private UniversalAccess auth-warn
// prompt bundle so it matches what the user sees in System Settings, falling
// back to the localized catalog strings.
enum AccessibilityPermission {
    static var displayName: String {
        if let appleName = appleLocalizedAccessibilityName() {
            return appleName
        }
        if #available(macOS 27, *) {
            return String(localized: "Device Control and Data Access")
        } else {
            return String(localized: "Accessibility")
        }
    }

    static var systemImageName: String {
        if #available(macOS 27, *) {
            return "folder.badge.gearshape"
        } else {
            return "accessibility"
        }
    }

    private static let osLocalizationPath =
        "/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Resources/universalAccessAuthWarn.app/Contents/Resources/Localizable.loctable"

    private static let osPermissionKey = "window.title.accessibility"

    private static let osLocalizedNameTables: [String: [String: String]]? = {
        guard let plist = NSDictionary(contentsOfFile: osLocalizationPath) else {
            return nil
        }
        var tables: [String: [String: String]] = [:]
        for (key, value) in plist {
            guard let locale = key as? String, let entries = value as? [String: Any] else {
                continue
            }
            tables[locale] = entries.compactMapValues { $0 as? String }
        }
        return tables
    }()

    private static func appleLocalizedAccessibilityName() -> String? {
        guard let tables = osLocalizedNameTables else {
            return nil
        }
        for locale in preferredLocaleCandidates {
            if let name = tables[locale]?[osPermissionKey] {
                return name
            }
        }
        return tables["en"]?[osPermissionKey]
    }

    private static var preferredLocaleCandidates: [String] {
        let preferred = Bundle.main.preferredLocalizations + Locale.preferredLanguages
        var candidates: [String] = []
        for preference in preferred {
            let identifier = preference.replacingOccurrences(of: "-", with: "_")
            candidates.append(identifier)
            if identifier.hasPrefix("zh_Hans") {
                candidates.append("zh_CN")
            } else if identifier.hasPrefix("zh_Hant") {
                candidates.append("zh_TW")
                candidates.append("zh_HK")
            }
            if let language = identifier.split(separator: "_", maxSplits: 1).first {
                candidates.append(String(language))
            }
        }
        return candidates
    }
}

// Define notification names at file scope
extension Notification.Name {
    // MARK: - Display
    static let selectedScreenChanged = Notification.Name("SelectedScreenChanged")
    /// Settings asks for the setup walkthrough again.
    static let showOnboarding = Notification.Name("ShowOnboarding")
    static let notchHeightChanged = Notification.Name("NotchHeightChanged")
    static let showOnAllDisplaysChanged = Notification.Name("showOnAllDisplaysChanged")
    static let automaticallySwitchDisplayChanged = Notification.Name("automaticallySwitchDisplayChanged")

    // MARK: - Shelf
    static let expandedDragDetectionChanged = Notification.Name("expandedDragDetectionChanged")

    // MARK: - System
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")

    // MARK: - Sharing
    static let sharingDidFinish = Notification.Name("com.boringNotch.sharingDidFinish")

    // MARK: - UI
    static let accentColorChanged = Notification.Name("AccentColorChanged")
}

// Media controller types for selection in settings
enum MediaControllerType: String, CaseIterable, Identifiable, Defaults.Serializable {
    case nowPlaying
    case appleMusic
    case spotify
    case youtubeMusic

    var id: String { self.rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "nowPlaying", "Now Playing": self = .nowPlaying
        case "appleMusic", "Apple Music": self = .appleMusic
        case "spotify", "Spotify": self = .spotify
        case "youtubeMusic", "YouTube Music": self = .youtubeMusic
        default: return nil
        }
    }

    init?(nowPlayingBundleIdentifier bundleIdentifier: String) {
        switch bundleIdentifier {
        case "com.apple.Music":
            self = .appleMusic
        case "com.spotify.client":
            self = .spotify
        case YouTubeMusicConfiguration.default.bundleIdentifier:
            self = .youtubeMusic
        default:
            return nil
        }
    }

    var localizedResource: LocalizedStringResource {
        switch self {
        case .nowPlaying:
            "Now Playing"
        case .appleMusic:
            "Apple Music"
        case .spotify:
            "Spotify"
        case .youtubeMusic:
            "YouTube Music"
        }
    }

    var localizedString: String {
        String(localized: localizedResource)
    }
}

// Sneak peek styles for selection in settings
enum SneakPeekStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case standard
    case inline

    var id: String { self.rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "standard", "Default": self = .standard
        case "inline", "Inline": self = .inline
        default: return nil
        }
    }

    var localizedString: String {
        switch self {
        case .standard:
            return String(localized: "Default", comment: "Sneak Peek style: Default")
        case .inline:
            return String(localized: "Inline", comment: "Sneak Peek style: Inline")
        }
    }
}

// Action to perform when Option (⌥) is held while pressing media keys
enum OptionKeyAction: String, CaseIterable, Identifiable, Defaults.Serializable {
    case openSettings
    case showOSD
    case none

    var id: String { self.rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "openSettings", "Open System Settings": self = .openSettings
        case "showOSD", "Show HUD": self = .showOSD
        case "none", "No Action": self = .none
        default: return nil
        }
    }

    var localizedString: String {
        switch self {
        case .openSettings:
            return String(localized: "Open System Settings", comment: "Option (⌥) key behavior: Open System Settings")
        case .showOSD:
            return String(localized: "Show OSD", comment: "Option (⌥) key behavior: Show OSD")
        case .none:
            return String(localized: "No action", comment: "Option (⌥) key behavior: No action")
        }
    }
}

// Source/provider for OSD control (user-facing: "Source")
enum OSDControlSource: String, CaseIterable, Identifiable, Defaults.Serializable {
    case builtin
    case betterDisplay = "BetterDisplay"
    case lunar = "Lunar"

    var id: String { self.rawValue }

    var localizedString: String {
        switch self {
        case .builtin:
            return String(localized: "Built-in", comment: "OSD Sources: Built-in")
        case .betterDisplay:
            return "BetterDisplay"
        case .lunar:
            return "Lunar"
        }
    }
}

enum PreferenceCompatibility {
    /// Runs before Defaults.Key registers its fallback, so a saved false is
    /// distinguishable from a missing value. Keep the old key for older builds.
    static func migratedKeyName(
        _ name: String,
        from legacyName: String,
        in defaults: UserDefaults = .standard
    ) -> String {
        if defaults.object(forKey: name) == nil,
           let legacyValue = defaults.object(forKey: legacyName) as? Bool {
            defaults.set(legacyValue, forKey: name)
        }
        return name
    }
}
