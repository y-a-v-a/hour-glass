/// One reading of the watch's motion, in g, in the device frame Core Motion uses: x towards
/// 3 o'clock, y towards 12 o'clock, z out of the screen.
public struct MotionSample: Sendable, Equatable {
    public var gravityX: Float, gravityY: Float, gravityZ: Float
    public var userX: Float, userY: Float, userZ: Float

    public init(gravityX: Float, gravityY: Float, gravityZ: Float,
                userX: Float = 0, userY: Float = 0, userZ: Float = 0) {
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.userX = userX
        self.userY = userY
        self.userZ = userZ
    }

    /// Held upright, 12 o'clock up, perfectly still.
    public static let upright = MotionSample(gravityX: 0, gravityY: -1, gravityZ: 0)
}

/// What the sand feels, in simulation units.
public struct SandForces: Sendable, Equatable {
    /// Acceleration in cells per step², x right and y down the screen.
    public var ax: Float, ay: Float
    /// Size of random kicks, in cells per step.
    public var agitation: Float
    /// Speed lost per step sliding on the glass, in cells per step.
    public var drag: Float

    public init(ax: Float, ay: Float, agitation: Float = 0, drag: Float = 0) {
        self.ax = ax
        self.ay = ay
        self.agitation = agitation
        self.drag = drag
    }
}

/// Turns watch motion into forces on the sand.
///
/// The sand feels whatever the accelerometer feels: gravity, plus the opposite of the watch's own
/// acceleration. Core Motion splits the raw reading into `gravity + userAcceleration`, so adding
/// the two back together is exactly the apparent acceleration of a loose grain inside the watch —
/// flick your wrist right and the sand slams into the left wall, then the right one as you stop.
public struct MotionMapping: Sendable {
    /// Cells per step² for 1 g in the plane of the screen.
    public var gravityScale: Float
    /// How strongly the wrist's own acceleration moves the sand, relative to gravity.
    public var shakeGain: Float = 1.6
    /// Wrist jerks smaller than this (in g) are ignored, so a steady hand doesn't make sand twitch.
    public var shakeDeadZone: Float = 0.04
    /// Friction against the glass the sand lies on, as a fraction of the force pressing it there.
    /// It's why sand stays put when the watch is held flat, and you can draw in it.
    public var glassFriction: Float = 0.14
    /// Random kicks per g of bump into or out of the screen: tapping the watch makes the sand hop.
    public var hopGain: Float = 1.4
    /// The screen is turned half a turn (Digital Crown worn on the left), so x and y swap sign.
    public var flipped = false

    public init(gravityScale: Float) {
        self.gravityScale = gravityScale
    }

    /// Scaled so sand crosses the screen at the same speed on any grid height, for
    /// `SandWorld.stepsPerFrame` steps per frame.
    public static func tuned(forHeight height: Int) -> MotionMapping {
        MotionMapping(gravityScale: 0.25 * max(0.5, Float(height) / 165))
    }

    public func forces(for s: MotionSample) -> SandForces {
        func deadZone(_ v: Float) -> Float {
            abs(v) <= shakeDeadZone ? 0 : v - (v > 0 ? shakeDeadZone : -shakeDeadZone)
        }
        // Device y points up the screen; the simulation's y points down.
        var x = s.gravityX + shakeGain * deadZone(s.userX)
        var y = -(s.gravityY + shakeGain * deadZone(s.userY))
        if flipped {
            x = -x
            y = -y
        }

        // Coulomb friction against the glass: the in-plane pull has to beat it to move anything.
        let pressing = abs(s.gravityZ + s.userZ)
        let inPlane = (x * x + y * y).squareRoot()
        let free = max(0, inPlane - glassFriction * pressing)
        let k = inPlane > 0.0001 ? free / inPlane : 0

        let hop = max(0, abs(s.userZ) - 0.12) * hopGain
            + max(0, (s.userX * s.userX + s.userY * s.userY).squareRoot() - 1.2) * 0.25
        // Sliding friction is a little lower than sticking friction.
        let drag = 0.8 * glassFriction * pressing * gravityScale
        return SandForces(ax: x * k * gravityScale, ay: y * k * gravityScale,
                          agitation: min(hop, 1.5), drag: drag)
    }
}
