//
//  RainbowCatSettingsView.swift
//  boringNotch
//
import Defaults
import SwiftUI

struct RainbowCatSettingsView: View {
    @Default(.rainbowCat) private var enabled

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    RainbowCat()
                        .frame(width: RainbowCatNSView.size.width, height: RainbowCatNSView.size.height)
                        .scaleEffect(2)
                        .frame(width: RainbowCatNSView.size.width * 2, height: RainbowCatNSView.size.height * 2)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 24)
                        .background(Capsule().fill(.black))
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }

            Section {
                Defaults.Toggle(key: .rainbowCat) {
                    Text("Show the rainbow cat")
                }
            } footer: {
                Text("While nothing plays, a pixel cat with a piano keyboard for a body runs on the right of the closed notch, with an empty wing of the same width on the left. It runs faster the busier the CPU is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .rainbowCatInPlayer) {
                    Text("Replace the waveform while playing")
                }
                Defaults.Toggle(key: .rainbowCatSystemMonitor) {
                    Text("Open the system monitor from the cat")
                }
            } footer: {
                Text("While media plays, the cat takes the waveform's place beside the album art, and coloured notes float off behind it instead of the rainbow, more of them the louder the music. Hovering over the cat or clicking it opens CPU, memory, network, storage, battery and energy use instead of the usual tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .accentColor(.effectiveAccent)
        .navigationTitle("Rainbow Cat")
    }
}
