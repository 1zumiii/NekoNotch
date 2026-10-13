//
//  MixerSettingsView.swift
//  boringNotch
//
import Defaults
import SwiftUI

struct MixerSettingsView: View {
    @ObservedObject private var engine = AudioMixerEngine.shared

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .showMixerTab) {
                    Text("Show mixer tab")
                }
            } footer: {
                Text("Set a volume for each app that is playing sound, mute it, or send it to a different output. Apps you haven't touched are left alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                feature(
                    "slider.horizontal.below.rectangle",
                    "Per-app volume",
                    "Drag an app's slider (up to 150%), or double-click it to go back to 100%. The faint colored bar inside the slider is the app's live level."
                )
                feature(
                    "speaker.slash",
                    "Mute and solo",
                    "The speaker button mutes one app. Open the arrow at the end of a row and press S to hear only that app."
                )
                feature(
                    "arrow.triangle.branch",
                    "Output routing",
                    "In the opened row, send an app to a different output device, or leave it on the system default."
                )
                feature(
                    "circle.lefthalf.filled",
                    "Balance and mono",
                    "Shift an app's sound to the left or right, or fold it down to mono (M)."
                )
                feature(
                    "hifispeaker.and.homepod",
                    "System and microphone",
                    "The two cards on the left switch the default output and input device, and set their volume and mute."
                )
                feature(
                    "bookmark",
                    "Scenes",
                    "Save all your app settings under a name and bring them back with one click from the Scenes button."
                )
            } header: {
                Text("What you can do")
            }

            Section {
                Defaults.Toggle(key: .mixerShowMeters) {
                    Text("Show level meters")
                }
            } footer: {
                Text("Meters listen to each playing app without changing its sound. Turn them off to save a little CPU.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Apps you change are re-routed through Boring Notch, which adds a few milliseconds of delay. Audio protected by copy protection can't be captured and may stay silent or unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset all app volumes and outputs") {
                    engine.resetAll()
                }
                .disabled(engine.settings.isEmpty)
            } header: {
                Text("Notes")
            }
        }
        .formStyle(.grouped)
        .accentColor(.effectiveAccent)
        .navigationTitle("Mixer")
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(Color.effectiveAccent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
