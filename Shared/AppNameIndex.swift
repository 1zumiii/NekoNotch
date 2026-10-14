//
//  AppNameIndex.swift
//  boringNotch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit
import Foundation

/// Installed apps by name, built once in the background.
///
/// A notification banner only carries the app's *display* name, often
/// localised ("脚本编辑器"). Finding the app behind it by opening every bundle
/// in /Applications took over a second per unknown name, right on the path
/// that puts the notification on screen. The index is built off that path, and
/// a lookup is a pass over an in-memory list.
final class AppNameIndex: @unchecked Sendable {
    static let shared = AppNameIndex()

    private struct Entry {
        let name: String
        let bundleID: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var isReady = false
    private var isBuilding = false
    private var builtAt = Date.distantPast

    /// A miss may only mean the app was installed recently: rebuild at most this often.
    private static let refreshInterval: TimeInterval = 120

    private static var directories: [URL] {
        let home = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: home).appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    /// Start building in the background. Safe to call repeatedly.
    func warmUp() {
        rebuild()
    }

    /// The bundle ID of the first installed app having a name for which
    /// `matches` is true, or nil when none does (or the index isn't built yet).
    func bundleID(whereName matches: (String) -> Bool) -> String? {
        lock.lock()
        let snapshot = entries
        let ready = isReady
        let age = Date().timeIntervalSince(builtAt)
        lock.unlock()

        if let hit = snapshot.first(where: { matches($0.name) }) { return hit.bundleID }
        if !ready || age > Self.refreshInterval { rebuild() }
        return nil
    }

    private func rebuild() {
        lock.lock()
        guard !isBuilding else { lock.unlock(); return }
        isBuilding = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            var built: [Entry] = []
            for directory in Self.directories {
                guard let urls = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
                ) else { continue }
                for url in urls where url.pathExtension == "app" {
                    guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
                    var names: [String?] = [
                        url.deletingPathExtension().lastPathComponent,
                        // What Finder shows: the localised name.
                        (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension,
                        bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                        bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ]
                    names.append(bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                    names.append(bundle.localizedInfoDictionary?["CFBundleName"] as? String)
                    var seen = Set<String>()
                    for name in names.compactMap({ $0 }) where !name.isEmpty && seen.insert(name).inserted {
                        built.append(Entry(name: name, bundleID: bundleID))
                    }
                }
            }
            lock.lock()
            entries = built
            isReady = true
            builtAt = Date()
            isBuilding = false
            lock.unlock()
        }
    }
}
