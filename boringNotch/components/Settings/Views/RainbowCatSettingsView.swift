//
//  RainbowCatSettingsView.swift
//  boringNotch
//
import Defaults
import SwiftUI

struct RainbowCatSettingsView: View {
    @Default(.rainbowCat) private var enabled
    @Default(.rainbowCatMaxSpeed) private var catMaxSpeed
    @Default(.rainbowCatSkyMaxSpeed) private var skyMaxSpeed
    @Default(.rainbowCatWarp) private var warp
    @Default(.rainbowCatWarpThreshold) private var warpThreshold
    @State private var test: PreviewTest?
    @State private var testEnd: Task<Void, Never>?

    /// States the test buttons show for a few seconds, in the preview above
    /// and on the notch alike.
    private enum PreviewTest: CaseIterable {
        case idle, busy, warp, full, singing

        var title: LocalizedStringKey {
            switch self {
            case .idle: "Idle"
            case .busy: "Half load"
            case .warp: "Warp"
            case .full: "Full load"
            case .singing: "Singing"
            }
        }
    }

    private static let testDuration: TimeInterval = 15

    var body: some View {
        Form {
            Section {
                preview
                    .listRowBackground(Color.clear)
            }

            Section {
                HStack {
                    ForEach(PreviewTest.allCases, id: \.self) { item in
                        Button {
                            run(item)
                        } label: {
                            Text(item.title)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(test == item ? .accentColor : nil)
                    }
                }
            } header: {
                Text("Test")
            } footer: {
                Text("Each button shows a state for fifteen seconds, here and on the notch, then the cat goes back to the real CPU load. Warp uses a load just past the threshold set below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!enabled)

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
                Defaults.Toggle(key: .rainbowCatNotesFollowVolume) {
                    Text("Notes follow the volume")
                }
                Defaults.Toggle(key: .rainbowCatSystemMonitor) {
                    Text("Open the system monitor from the cat")
                }
            } footer: {
                Text("While media plays, the cat takes the waveform's place beside the album art, and coloured notes float off behind it instead of the rainbow, at a steady pace, or more of them the louder the music when they follow the volume (this needs the realtime audio waveform). Hovering over the cat or clicking it opens CPU, memory, network, storage, battery and energy use instead of the usual tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!enabled)

            Section {
                Defaults.Toggle(key: .rainbowCatMenuAvoidance) {
                    Text("Make way for app menus")
                }
            } footer: {
                Text("When an app has so many menus that the starry wing left of the notch covers the last of them, the wing folds away as the pointer comes over it, and opens again once the pointer has left the menu bar and no menu is open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!enabled)

            Section {
                speedSlider("Cat at its fastest", value: $catMaxSpeed, range: 1...6, step: 0.5)
                speedSlider("Stars at their fastest", value: $skyMaxSpeed, range: 1...10, step: 0.5)
                Toggle(isOn: $warp) {
                    Text("Warp speed")
                }
                HStack {
                    Text("Warp from CPU load")
                    Slider(value: $warpThreshold, in: 0.3...0.95, step: 0.05)
                    Text(verbatim: "\(Int((warpThreshold * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!warp)
            } header: {
                Text("Speed")
            } footer: {
                Text("The cat and the stars speed up with the CPU load, from their resting pace up to the speeds above: reached at the warp threshold with warp speed on, at full load with it off. With warp speed on, past the threshold the stars give way to streaks of light; they come back once the load drops 10% below it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .accentColor(.effectiveAccent)
        .navigationTitle("Rainbow Cat")
    }

    /// The closed notch at twice the size, across the whole row, with the
    /// cutout left out: one sky behind it all and the cat on the right.
    private var preview: some View {
        let scale: CGFloat = 2
        let cat = RainbowCatNSView.size
        return GeometryReader { geometry in
            let width = max(cat.width, (geometry.size.width - 24) / scale)
            ZStack(alignment: .trailing) {
                RainbowStars()
                    .frame(width: width, height: cat.height)
                    .clipped()
                // Not active: "Singing" is a preview, so the notes come at a
                // steady pace rather than following what is really playing.
                RainbowCat(isPlaying: test == .singing, isActive: false, showsSky: false)
                    .frame(width: cat.width, height: cat.height)
            }
            .scaleEffect(scale)
            .frame(width: width * scale, height: cat.height * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black))
        }
        .frame(height: cat.height * scale + 28)
    }

    private func run(_ item: PreviewTest) {
        let load: Double? = switch item {
        case .idle: 0
        case .busy: 0.5
        case .warp: min(1, warpThreshold + 0.05)
        case .full: 1
        case .singing: nil
        }
        CPULoadMonitor.shared.simulate(load, for: Self.testDuration)
        test = item
        testEnd?.cancel()
        testEnd = Task {
            try? await Task.sleep(for: .seconds(Self.testDuration))
            guard !Task.isCancelled else { return }
            test = nil
        }
    }

    private func speedSlider(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: step)
            Text(verbatim: String(format: "%.1f×", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
    }
}
