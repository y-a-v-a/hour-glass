import CoreMotion
import Foundation
import HourGlassCore
import WatchKit

/// Reads the watch's motion once per frame. Polling suits a render loop better than a callback
/// queue: there's always exactly one fresh sample when a frame needs it.
@MainActor
final class MotionReader {
    private let manager = CMMotionManager()
    private var demoStart = Date()

    /// Whether real motion data is available. It isn't in the simulator.
    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    /// Set with the `-demo` launch argument: without real motion, sway gravity around so the
    /// simulator shows the sand moving.
    let demo = ProcessInfo.processInfo.arguments.contains("-demo")

    func start() {
        guard isAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60
        manager.startDeviceMotionUpdates()
        demoStart = Date()
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// The latest reading, or a stand-in when there's no motion hardware.
    func sample(at date: Date) -> MotionSample {
        if let motion = manager.deviceMotion {
            return MotionSample(
                gravityX: Float(motion.gravity.x), gravityY: Float(motion.gravity.y),
                gravityZ: Float(motion.gravity.z),
                userX: Float(motion.userAcceleration.x), userY: Float(motion.userAcceleration.y),
                userZ: Float(motion.userAcceleration.z))
        }
        guard demo else {
            // Held up in front of you, tipped back a little, like a raised wrist.
            return MotionSample(gravityX: 0, gravityY: -0.8, gravityZ: -0.6)
        }
        // Rock slowly from side to side, with a full turn now and then.
        let t = date.timeIntervalSince(demoStart)
        let angle = sin(t * 0.45) * 1.3 + (t.truncatingRemainder(dividingBy: 24) > 18 ? .pi : 0)
        return MotionSample(gravityX: Float(-sin(angle)) * 0.85, gravityY: Float(-cos(angle)) * 0.85,
                            gravityZ: -0.5)
    }

    /// The display is upside down relative to the motion sensors when the Digital Crown is worn
    /// on the left.
    var screenIsFlipped: Bool {
        WKInterfaceDevice.current().crownOrientation == .left
    }
}
