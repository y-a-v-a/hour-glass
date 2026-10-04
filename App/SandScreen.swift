import HourGlassCore
import SwiftUI

/// The sand, redrawn every frame, with touch handling and the hourglass countdown.
struct SandScreen: View {
    let controller: SandController
    let palette: SandPalette
    let mode: SandMode
    /// The hourglass's turn while it's being flipped, in degrees.
    let flipAngle: Double
    /// Shown big in the middle while the Digital Crown sets the timer.
    let badge: String?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.scenePhase) private var phase

    @State private var touchStart: Date?
    @State private var dragging = false

    var body: some View {
        ZStack {
            Backdrop(palette: palette)
            // Asleep, the sand only needs checking now and then for the wrist moving.
            TimelineView(.animation(minimumInterval: controller.activity.isAsleep ? 0.2 : 1.0 / 60,
                                    paused: dimmed || phase != .active)) { timeline in
                ZStack {
                    Canvas(rendersAsynchronously: false) { ctx, size in
                        controller.frame(at: timeline.date, size: size, scale: displayScale)
                        SandDrawing.draw(in: &ctx, controller: controller)
                    }
                    .rotationEffect(.degrees(flipAngle),
                                    anchor: UnitPoint(x: controller.turnAnchor.x, y: controller.turnAnchor.y))

                    if mode == .hourglass {
                        countdown
                            .opacity(flipAngle == 0 ? 1 : 0)
                    }
                }
            }
            if let badge {
                Text(badge)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if dimmed {
                // Always-on display: hold the last frame, dimmed.
                Color.black.opacity(0.4).ignoresSafeArea()
            }
        }
        .contentShape(Rectangle())
        .gesture(touch)
        .accessibilityElement()
        .accessibilityLabel(mode == .hourglass ? "Hourglass" : "Sand")
        .accessibilityValue(mode == .hourglass ? countdownText(controller.remaining) + " left" : "")
    }

    /// The time left, engraved on the bottom cap.
    @ViewBuilder
    private var countdown: some View {
        if let glass = controller.container?.glass {
            let cap = SandDrawing.bottomCap(of: glass, controller: controller)
            Text(countdownText(controller.displayedTime))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 1, green: 0.88, blue: 0.62).opacity(controller.isTiming ? 0.95 : 0.6))
                .shadow(color: .black.opacity(0.6), radius: 0.5, y: 0.5)
                .position(x: cap.midX, y: cap.midY)
        }
    }

    /// A quick tap scatters sand; a drag ploughs through it.
    private var touch: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if touchStart == nil { touchStart = value.time }
                let moved = hypot(value.translation.width, value.translation.height)
                if dragging || moved > 6 {
                    dragging = true
                    controller.drag(to: value.location)
                }
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height)
                let held = value.time.timeIntervalSince(touchStart ?? value.time)
                if !dragging && moved <= 6 && held < 0.4 {
                    controller.tap(at: value.location)
                }
                controller.endDrag()
                dragging = false
                touchStart = nil
            }
    }
}
