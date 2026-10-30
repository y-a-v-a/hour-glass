import HourGlassCore
import SwiftUI

struct ContentView: View {
    @AppStorage(SettingsKey.mode) private var modeID = SandMode.sandbox.rawValue
    @AppStorage(SettingsKey.palette) private var paletteID = SandPalette.sahara.id
    @AppStorage(SettingsKey.grain) private var grainID = GrainSize.medium.rawValue
    @AppStorage(SettingsKey.haptics) private var hapticsOn = true
    @AppStorage(SettingsKey.fill) private var fill = 0.38
    @AppStorage(SettingsKey.timer) private var timerSeconds = HourglassDurations.standard

    @State private var controller = SandController()
    @State private var showSettings = false
    @State private var timerIndex = Double(HourglassDurations.index(of: HourglassDurations.standard))
    @State private var flipAngle = 0.0
    @State private var badge: String?
    @State private var badgeTask: Task<Void, Never>?
    @FocusState private var crownFocused: Bool

    @Environment(\.scenePhase) private var phase
    @Environment(\.isLuminanceReduced) private var dimmed

    private var mode: SandMode { SandMode(rawValue: modeID) ?? .sandbox }
    private var palette: SandPalette { SandPalette.named(paletteID) }
    private var grain: GrainSize { GrainSize(rawValue: grainID) ?? .medium }

    var body: some View {
        NavigationStack {
            SandScreen(controller: controller, palette: palette, mode: mode, grain: grain,
                       flipAngle: flipAngle, badge: badge)
                .ignoresSafeArea()
                .focusable()
                .focusEffectDisabled()
                .focused($crownFocused)
                .modifier(CrownControl(mode: mode, fill: $fill, timerIndex: $timerIndex))
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .accessibilityLabel("Settings")
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Spacer()
                        Button(action: primaryAction) {
                            Image(systemName: mode == .hourglass ? "hourglass" : "wind")
                        }
                        .accessibilityLabel(mode == .hourglass ? "Turn over" : "Stir")
                        .modifier(DoubleTapShortcut())
                    }
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(modeID: $modeID, paletteID: $paletteID, grainID: $grainID,
                         hapticsOn: $hapticsOn, timerSeconds: $timerSeconds) {
                refill()
            }
        }
        .onAppear {
            timerIndex = Double(HourglassDurations.index(of: timerSeconds))
            apply()
            controller.resume(at: .now)
            crownFocused = true
            // For screenshots and demos in the simulator, where there's no wrist to turn.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-turnOver") {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    turnOver()
                }
            }
            if arguments.contains("-openSettings") { showSettings = true }
        }
        .onChange(of: modeID) { apply() }
        .onChange(of: paletteID) { apply() }
        .onChange(of: grainID) { apply() }
        .onChange(of: hapticsOn) { apply() }
        .onChange(of: fill) { controller.fill = fill }
        .onChange(of: timerIndex) {
            let index = max(0, min(HourglassDurations.all.count - 1, Int(timerIndex.rounded())))
            let seconds = HourglassDurations.all[index]
            if seconds != timerSeconds {
                timerSeconds = seconds
                showBadge(HourglassDurations.label(seconds))
            }
        }
        .onChange(of: timerSeconds) { controller.timerSeconds = timerSeconds }
        .onChange(of: showSettings) {
            if !showSettings { crownFocused = true }
        }
        .onChange(of: phase) { updateActivity() }
        .onChange(of: dimmed) { updateActivity() }
    }

    private func apply() {
        controller.mode = mode
        controller.grain = grain
        controller.setPalette(palette)
        controller.haptics.isEnabled = hapticsOn
        controller.fill = fill
        controller.timerSeconds = timerSeconds
    }

    private func updateActivity() {
        if phase == .active && !dimmed {
            controller.resume(at: .now)
        } else {
            controller.suspend(at: .now, showing: dimmed)
        }
    }

    private func primaryAction() {
        switch mode {
        case .sandbox: controller.stir()
        case .hourglass: turnOver()
        }
    }

    /// Spins the hourglass end over end, then swaps the sand to match.
    private func turnOver() {
        guard flipAngle == 0 else { return }
        controller.isPaused = true
        withAnimation(.easeInOut(duration: 0.7)) {
            flipAngle = 180
        } completion: {
            controller.flip()
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { flipAngle = 0 }
            controller.isPaused = false
        }
    }

    private func refill() {
        switch mode {
        case .sandbox: controller.restartPour()
        case .hourglass: controller.refillHourglass()
        }
    }

    private func showBadge(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) { badge = text }
        badgeTask?.cancel()
        badgeTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { badge = nil }
        }
    }
}

/// The Digital Crown pours sand in the sandbox and sets the timer on the hourglass.
private struct CrownControl: ViewModifier {
    let mode: SandMode
    @Binding var fill: Double
    @Binding var timerIndex: Double

    func body(content: Content) -> some View {
        switch mode {
        case .sandbox:
            content.digitalCrownRotation($fill, from: 0.04, through: 0.78, by: 0.01,
                                         sensitivity: .low, isContinuous: false,
                                         isHapticFeedbackEnabled: true)
        case .hourglass:
            content.digitalCrownRotation($timerIndex, from: 0, through: Double(HourglassDurations.all.count - 1),
                                         by: 1, sensitivity: .low, isContinuous: false,
                                         isHapticFeedbackEnabled: true)
        }
    }
}

/// Double tap (thumb and finger, Series 9 and Ultra 2 onwards) presses the button.
private struct DoubleTapShortcut: ViewModifier {
    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.handGestureShortcut(.primaryAction)
        } else {
            content
        }
    }
}
