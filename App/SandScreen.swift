import HourGlassCore
import SwiftUI

/// The sand, redrawn every frame, with touch handling and the hourglass countdown.
struct SandScreen: View {
    let controller: SandController
    let palette: SandPalette
    let mode: SandMode
    let grain: GrainSize
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
            GeometryReader { proxy in
                if let layout = controller.layout(for: proxy.size, scale: displayScale, grain: grain, mode: mode) {
                    stage(layout)
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
        .accessibilityValue(mode == .hourglass ? countdownText(Double(controller.activity.countdown)) + " left" : "")
    }

    /// The sand between the glass and the frame, which only change with the layout.
    private func stage(_ layout: SandLayout) -> some View {
        let glass = controller.container?.glass
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if let glass { GlassBack(glass: glass, layout: layout) }
                sand(layout)
                if let glass {
                    GlassFront(glass: glass, layout: layout)
                } else {
                    Sheen(rect: layout.gridRect)
                }
            }
            .rotationEffect(.degrees(flipAngle), anchor: layout.turnAnchor)

            if mode == .hourglass, let glass {
                Countdown(activity: controller.activity, cap: SandDrawing.bottomCap(of: glass, layout: layout))
                    .opacity(flipAngle == 0 ? 1 : 0)
            }
        }
        .frame(width: layout.viewSize.width, height: layout.viewSize.height, alignment: .topLeading)
    }

    /// While the screen is live, a new image of the sand every frame; otherwise (the always-on
    /// display, or the app not in front) the last one, with no timeline running at all.
    @ViewBuilder
    private func sand(_ layout: SandLayout) -> some View {
        if dimmed || phase != .active {
            SandImage(image: controller.frame(at: .now, live: false), rect: layout.gridRect)
        } else {
            // Asleep, the sand only needs checking now and then for the wrist moving.
            TimelineView(.animation(minimumInterval: controller.activity.isAsleep ? 0.2 : 1.0 / 60)) { timeline in
                SandImage(image: controller.frame(at: timeline.date, live: timeline.cadence == .live),
                          rect: layout.gridRect)
            }
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

/// One pixel per grain, scaled up without smoothing so every grain stays crisp. A plain image
/// rather than a canvas, so a new frame is just new contents for its layer.
private struct SandImage: View {
    let image: CGImage?
    let rect: CGRect

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
    }
}

/// The time left, engraved on the bottom cap.
private struct Countdown: View {
    let activity: SandActivity
    let cap: CGRect

    var body: some View {
        Text(countdownText(Double(activity.countdown)))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(red: 1, green: 0.88, blue: 0.62).opacity(activity.isTiming ? 0.95 : 0.6))
            .shadow(color: .black.opacity(0.6), radius: 0.5, y: 0.5)
            .position(x: cap.midX, y: cap.midY)
    }
}
