//
//  AboutView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import SwiftUI

struct AboutView: View {
    static let repositoryURL = URL(string: "https://github.com/\(UpdateChecker.repository)")!
    static let upstreamURL = URL(string: "https://github.com/TheBoredTeam/boring.notch")!
    /// The upstream release this project started from.
    static let upstreamBase = "2.8-rc.2"

    @ObservedObject private var updates = UpdateChecker.shared
    @Default(.checkForUpdates) private var checkForUpdates
    @State private var showBuildNumber = false

    private var version: String { UpdateChecker.currentVersion }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    /// Opens a new issue on this project's repository with the version and
    /// the macOS release filled in.
    private var bugReportURL: URL? {
        var components = URLComponents(string: "\(Self.repositoryURL.absoluteString)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "body", value: """
                **Version:** \(version) (\(build))
                **macOS:** \(ProcessInfo.processInfo.operatingSystemVersionString)

                **What happened:**

                """),
        ]
        return components?.url
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        if showBuildNumber {
                            Text(verbatim: "(\(build))").foregroundStyle(.secondary)
                        }
                        Text(verbatim: version).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { showBuildNumber.toggle() } }
                    HStack {
                        Text("Repository")
                        Spacer()
                        Link(UpdateChecker.repository, destination: Self.repositoryURL)
                    }
                    HStack {
                        Text("Based on")
                        Spacer()
                        Link(destination: Self.upstreamURL) {
                            Text(verbatim: "Boring Notch \(Self.upstreamBase)")
                        }
                    }
                }

                Section {
                    Toggle("Check for updates automatically", isOn: $checkForUpdates)
                    HStack {
                        updateStatus
                        Spacer()
                        if case .available(_, let page) = updates.state {
                            Button("Download") { NSWorkspace.shared.open(page) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Check Now") {
                            Task { await updates.check(userInitiated: true) }
                        }
                        .disabled(updates.state == .checking)
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Looks up the latest release on GitHub, at most once a day. New versions are installed by hand from the release page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 30) {
                    Spacer(minLength: 0)
                    Button {
                        if let url = bugReportURL { NSWorkspace.shared.open(url) }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "exclamationmark.bubble")
                                .font(.system(size: 15, weight: .medium))
                                .frame(height: 18)
                            Text("Report a Bug")
                        }
                        .contentShape(Rectangle())
                    }
                    .help("Open a bug report with your version filled in automatically")
                    Button {
                        NSWorkspace.shared.open(Self.repositoryURL)
                    } label: {
                        VStack(spacing: 5) {
                            Image("Github")
                                .resizable().scaledToFit()
                                .frame(width: 18, height: 18)
                                .foregroundStyle(.primary)
                            Text("GitHub")
                        }
                        .contentShape(Rectangle())
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .formStyle(.grouped)
            VStack(spacing: 0) {
                Divider()
                Text("Made by 1zumiii, built on Boring Notch by The Bored Team.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("About")
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updates.state {
        case .idle:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let latest, _):
            Label("Version \(latest) is available", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .failed:
            Label("Couldn't reach GitHub", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}
