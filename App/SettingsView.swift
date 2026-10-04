import HourGlassCore
import SwiftUI

struct SettingsView: View {
    @Binding var modeID: String
    @Binding var paletteID: String
    @Binding var grainID: Int
    @Binding var hapticsOn: Bool
    @Binding var timerSeconds: Int
    /// Pours a fresh load of sand.
    let refill: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Picker("Mode", selection: $modeID) {
                    ForEach(SandMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }

                Picker("Sand", selection: $paletteID) {
                    ForEach(SandPalette.all) { palette in
                        HStack {
                            Swatch(palette: palette)
                            Text(palette.name)
                        }
                        .tag(palette.id)
                    }
                }

                Picker("Grain", selection: $grainID) {
                    ForEach(GrainSize.allCases) { grain in
                        Text(grain.title).tag(grain.rawValue)
                    }
                }

                if modeID == SandMode.hourglass.rawValue {
                    Picker("Timer", selection: $timerSeconds) {
                        ForEach(HourglassDurations.all, id: \.self) { seconds in
                            Text(HourglassDurations.label(seconds)).tag(seconds)
                        }
                    }
                }

                Toggle("Haptics", isOn: $hapticsOn)

                Button {
                    refill()
                    dismiss()
                } label: {
                    Label(modeID == SandMode.hourglass.rawValue ? "Reset Hourglass" : "Pour Fresh Sand",
                          systemImage: "arrow.counterclockwise")
                }

                Section {
                    Text(help)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sand")
        }
    }

    private var help: String {
        if modeID == SandMode.hourglass.rawValue {
            return "Turn your wrist over, or tap the hourglass button, to start the sand. "
                + "The Digital Crown sets the time. Double tap turns it over on watches that support it."
        }
        return "Tilt and flick your wrist to move the sand. Tap to scatter it, drag to draw in it. "
            + "Turn the Digital Crown to pour more in or let it out. Hold the watch flat to keep a drawing."
    }
}

/// A little pile of a palette's colours.
private struct Swatch: View {
    let palette: SandPalette

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(palette.tones.prefix(4).enumerated()), id: \.offset) { _, tone in
                Rectangle()
                    .fill(Color(red: Double(tone.r) / 255, green: Double(tone.g) / 255, blue: Double(tone.b) / 255))
                    .frame(width: 4, height: 14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
