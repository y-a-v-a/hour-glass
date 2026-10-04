import Foundation
import WatchKit

/// Turns sand hitting the walls into taps on the wrist, without drowning the Taptic Engine.
@MainActor
final class Haptics {
    var isEnabled = true

    private var lastTap = Date.distantPast
    private var lastThud = Date.distantPast
    /// Impact left over from frames too soft to feel on their own.
    private var pending: Float = 0

    /// Feeds one frame's worth of impact (see `SandWorld.lastImpact`), scaled to the grid so it
    /// feels the same whatever the grain size.
    func impact(_ amount: Float, at date: Date) {
        guard isEnabled else { return }
        pending = pending * 0.6 + amount
        if pending > 260, date.timeIntervalSince(lastThud) > 0.45 {
            // A real slam: a lot of sand hitting the glass at once.
            WKInterfaceDevice.current().play(.directionDown)
            lastThud = date
            lastTap = date
            pending = 0
        } else if pending > 30, date.timeIntervalSince(lastTap) > 0.14 {
            WKInterfaceDevice.current().play(.click)
            lastTap = date
            pending = 0
        }
    }

    func play(_ type: WKHapticType) {
        guard isEnabled else { return }
        WKInterfaceDevice.current().play(type)
    }
}

/// Keeps the app running while an hourglass is timing, so it can tap the wrist when the sand runs
/// out even with the screen off.
@MainActor
final class HourglassSession: NSObject, WKExtendedRuntimeSessionDelegate {
    private var session: WKExtendedRuntimeSession?
    private var alarm: Timer?

    /// When the alarm last went off.
    private(set) var rangAt: Date?

    func start() {
        guard session == nil || session?.state == .invalid else { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        self.session = session
    }

    func stop() {
        alarm?.invalidate()
        alarm = nil
        session?.invalidate()
        session = nil
    }

    /// Taps the wrist in `seconds`, unless rescheduled or cancelled first.
    func scheduleAlarm(in seconds: TimeInterval) {
        alarm?.invalidate()
        alarm = Timer.scheduledTimer(withTimeInterval: max(0.1, seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.ring() }
        }
    }

    func cancelAlarm() {
        alarm?.invalidate()
        alarm = nil
    }

    /// The sand has run out: tap the wrist twice, so it isn't missed, then let the session go.
    ///
    /// (`notifyUser(hapticType:)` would be the obvious call, but it's only for scheduled smart
    /// alarm sessions; a running mindfulness session keeps the app alive, and a running app may
    /// play haptics itself.)
    func ring() {
        alarm?.invalidate()
        alarm = nil
        rangAt = Date()
        let device = WKInterfaceDevice.current()
        device.play(.notification)
        let ending = session
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.3))
            device.play(.notification)
            try? await Task.sleep(for: .seconds(1))
            // Unless the hourglass has been turned over again meanwhile.
            if self.session === ending { self.stop() }
        }
    }

    nonisolated func extendedRuntimeSession(_ session: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: Error?) {
        Task { @MainActor in
            if self.session === session { self.session = nil }
        }
    }

    nonisolated func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {}
}
