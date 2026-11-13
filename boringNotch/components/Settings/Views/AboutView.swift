//
//  AboutView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import Sparkle
import SwiftUI

struct AboutView: View {
    @State private var showBuildNumber: Bool = false
    let updaterController: SPUStandardUpdaterController
    @Environment(\.openWindow) var openWindow

    /// The exact version this build reports, in the format the bug report
    /// form's validator recognizes (see .github/scripts/validate-issue-version.js).
    private var reportVersion: String {
        let version = Bundle.main.releaseVersionNumber ?? "unknown"
        let build = Bundle.main.buildVersionNumber ?? "unknown"
        let channel = UpdateChannel.bundled
        let channelSuffix = channel == .stable ? "" : ", \(channel.rawValue) channel"
        return "\(version) (build \(build)\(channelSuffix))"
    }

    static let repositoryURL = URL(string: "https://github.com/1zumiii/NekoNotch")!
    static let upstreamURL = URL(string: "https://github.com/TheBoredTeam/boring.notch")!

    /// Opens a new issue on this project's repository with the version and
    /// the macOS release filled in.
    private var bugReportURL: URL? {
        var components = URLComponents(string: "https://github.com/1zumiii/NekoNotch/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "body", value: """
                **Version:** \(CustomBuild.version) (\(reportVersion))
                **macOS:** \(ProcessInfo.processInfo.operatingSystemVersionString)

                **What happened:**

                """),
        ]
        return components?.url
    }

    var body: some View {
        VStack {
            Form {
                Section {
                    HStack {
                        Text("Release name")
                        Spacer()
                        Text(CustomBuild.releaseName)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        if showBuildNumber {
                            Text("(\(Bundle.main.buildVersionNumber ?? ""))")
                                .foregroundStyle(.secondary)
                        }
                        Text(CustomBuild.version)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Based on Boring Notch")
                        Spacer()
                        Text(Bundle.main.releaseVersionNumber ?? "unknown")
                            .foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        withAnimation {
                            showBuildNumber.toggle()
                        }
                    }
                } header: {
                    Text("Version info")
                }

                Section {
                    HStack {
                        Text("Repository")
                        Spacer()
                        Link("1zumiii/NekoNotch", destination: Self.repositoryURL)
                    }
                    HStack {
                        Text("Based on")
                        Spacer()
                        Link("TheBoredTeam/boring.notch", destination: Self.upstreamURL)
                    }
                }

                UpdaterSettingsView(updater: updaterController.updater)

                HStack(spacing: 30) {
                    Spacer(minLength: 0)
                    Button {
                        if let url = bugReportURL {
                            NSWorkspace.shared.open(url)
                        }
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
            VStack(spacing: 0) {
                Divider()
                Text("Made with 🫶🏻 by not so boring not.people")
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                    .padding(.bottom, 7)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .toolbar {
            CheckForUpdatesView(updater: updaterController.updater)
        }
        .navigationTitle("About")
    }
}
