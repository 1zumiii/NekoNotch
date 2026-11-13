//
//  UpdateChecker.swift
//  boringNotch
//
//  Looks up the latest release on GitHub and, when it is newer than this
//  build, offers a link to it. Nothing is downloaded or installed: the app
//  is not signed by a developer account, so it can't replace itself, and
//  the release page says how to install the new version.
//
//  GitHub's "latest release" leaves out drafts and prereleases, so a tag
//  such as v1.2.0-beta1 never reaches everyone this way.
//

import Defaults
import Foundation
import UserNotifications

extension Defaults.Keys {
    static let checkForUpdates = Key<Bool>("checkForUpdates", default: true)
    static let lastUpdateCheck = Key<Date?>("lastUpdateCheck", default: nil)
    /// The newest version a notification was already sent for.
    static let notifiedUpdateVersion = Key<String?>("notifiedUpdateVersion", default: nil)
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repository = "1zumiii/NekoNotch"
    static var releasesURL: URL { URL(string: "https://github.com/\(repository)/releases")! }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, page: URL)
        case failed
    }

    @Published private(set) var state: State = .idle

    /// This build's version, as the release tags spell it without the "v".
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static let interval: TimeInterval = 24 * 60 * 60
    private var timer: Timer?

    /// Checks once a day while automatic checks are on; the first check
    /// waits a little so it doesn't compete with launch.
    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        timer.tolerance = 10 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task {
            try? await Task.sleep(for: .seconds(30))
            checkIfDue()
        }
    }

    private func checkIfDue() {
        guard Defaults[.checkForUpdates] else { return }
        if let last = Defaults[.lastUpdateCheck], Date().timeIntervalSince(last) < Self.interval { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard state != .checking else { return }
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Defaults[.lastUpdateCheck] = Date()
            // No published release yet: nothing newer than this build.
            if status == 404 {
                state = .upToDate
                return
            }
            guard status == 200 else {
                state = .failed
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            if Self.isVersion(version, newerThan: Self.currentVersion), let page = URL(string: release.htmlURL) {
                state = .available(version: version, page: page)
                if !userInitiated { notifyOnce(version: version) }
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// Compares dotted numbers ("1.10.0" is newer than "1.9.2"); anything
    /// after a hyphen is ignored, as latest releases carry none.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// One notification per new version, and only if notifications were
    /// already allowed: an update is never a reason to ask for them.
    private func notifyOnce(version: String) {
        guard Defaults[.notifiedUpdateVersion] != version else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = String(localized: "NekoNotch \(version) is available")
            content.body = String(localized: "Open the About page in Settings to download it.")
            center.add(UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil))
            Task { @MainActor in Defaults[.notifiedUpdateVersion] = version }
        }
    }
}
