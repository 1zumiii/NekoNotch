//
//  NotificationDatabaseWatcher.swift
//  boringNotch
//
import AppKit
import Foundation
import SQLite3

/// Reads new notifications straight from Notification Center's database, so
/// apps can have their system banners switched off (nothing to flash) while
/// the notch still shows them. Needs Full Disk Access. Only records added
/// after the watcher starts are read, and nothing is stored.
final class NotificationDatabaseWatcher: @unchecked Sendable {
    static let shared = NotificationDatabaseWatcher()

    private let queue = DispatchQueue(label: "boringNotch.notificationDatabase", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var database: OpaquePointer?
    private var lastRecordID: Int64 = 0
    private var appIdentifiers: [Int64: String] = [:]
    private var resolvedApps: [String: (bundleID: String?, name: String)] = [:]

    private static let pollInterval: DispatchTimeInterval = .milliseconds(400)

    private static var databasePath: String {
        // NSHomeDirectory() is the sandbox container inside a sandboxed app.
        let home = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return home + "/Library/Group Containers/group.com.apple.usernoted/db2/db"
    }

    /// True when the database can be opened and queried (Full Disk Access).
    static func hasAccess() -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, "SELECT MAX(rec_id) FROM record", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            guard sqlite3_open_v2(Self.databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(database)
                database = nil
                return
            }
            lastRecordID = currentMaxRecordID()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            sqlite3_close(database)
            database = nil
            appIdentifiers.removeAll()
        }
    }

    private func currentMaxRecordID() -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT COALESCE(MAX(rec_id), 0) FROM record", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return lastRecordID }
        return sqlite3_column_int64(statement, 0)
    }

    private func poll() {
        guard let database else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT rec_id, app_id, data, uuid FROM record WHERE rec_id > ? ORDER BY rec_id"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_int64(statement, 1, lastRecordID)

        while sqlite3_step(statement) == SQLITE_ROW {
            let recordID = sqlite3_column_int64(statement, 0)
            let appID = sqlite3_column_int64(statement, 1)
            lastRecordID = max(lastRecordID, recordID)

            guard let bytes = sqlite3_column_blob(statement, 2) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
            // The first four bytes of the record's UUID: the same eight hex
            // digits the early log signal reports for this notification.
            var uuidPrefix: String?
            if let uuidBytes = sqlite3_column_blob(statement, 3), sqlite3_column_bytes(statement, 3) >= 4 {
                uuidPrefix = (0..<4).map { String(format: "%02X", uuidBytes.load(fromByteOffset: $0, as: UInt8.self)) }.joined()
            }
            publish(recordID: recordID, appID: appID, data: data, uuidPrefix: uuidPrefix)
        }
    }

    private func publish(recordID: Int64, appID: Int64, data: Data, uuidPrefix: String?) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let request = plist["req"] as? [String: Any] else { return }

        func text(_ key: String) -> String? {
            guard let value = (request[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        let title = text("titl"), subtitle = text("subt"), body = text("body")
        guard title != nil || body != nil else { return }

        let identifier = appIdentifier(for: appID)
        let app = identifier.map(resolveApp(identifier:))

        var payload: [String: String] = ["token": "db-\(recordID)"]
        if let uuidPrefix { payload["recordUUID"] = uuidPrefix }
        if let name = app?.name { payload["appName"] = name }
        if let bundleID = app?.bundleID ?? identifier { payload["bundleID"] = bundleID }
        if let title { payload["title"] = title }
        if let subtitle { payload["subtitle"] = subtitle }
        if let body { payload["body"] = body }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .systemNotificationDidAppear, object: nil, userInfo: payload)
        }
    }

    private func appIdentifier(for appID: Int64) -> String? {
        if let cached = appIdentifiers[appID] { return cached }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT identifier FROM app WHERE app_id = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_int64(statement, 1, appID)
        guard sqlite3_step(statement) == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0) else {
            return nil
        }
        let identifier = String(cString: cString)
        appIdentifiers[appID] = identifier
        return identifier
    }

    /// The database stores lowercase-ish identifiers; resolve the installed
    /// app so the bundle ID has its real casing and the name is displayable.
    private func resolveApp(identifier: String) -> (bundleID: String?, name: String) {
        if let cached = resolvedApps[identifier] { return cached }
        var result: (bundleID: String?, name: String) = (nil, identifier.split(separator: ".").last.map(String.init) ?? identifier)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier),
           let bundle = Bundle(url: url) {
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            result = (bundle.bundleIdentifier, name)
        }
        resolvedApps[identifier] = result
        return result
    }
}
