import CoreGraphics
import Foundation
import HourGlassCore
import WatchKit

/// Runs the sand: builds a world to fit the screen, steps it with the watch's motion and the
/// wearer's touches, keeps the hourglass's time, and renders each frame as an image.
///
/// It's a plain class rather than an observable one on purpose: it changes every frame, and the
/// view that shows the sand is redrawn every frame anyway by its `TimelineView`.
/// What the views do need to watch, and which changes far less often: whether the sand has gone to
/// sleep, so the render loop can slow down to just checking for motion, and the hourglass's
/// countdown, in whole seconds.
@MainActor @Observable
final class SandActivity {
    var isAsleep = false
    /// The time on the hourglass's cap, in whole seconds, and whether it's counting down.
    var countdown = 0
    var isTiming = false
    /// While the always-on display shows a running hourglass: its sand, a second at a time.
    var dimmedImage: CGImage?
}

@MainActor
final class SandController {
    let motion = MotionReader()
    let haptics = Haptics()
    let session = HourglassSession()
    let activity = SandActivity()

    // MARK: Settings

    var mode: SandMode = .sandbox
    var grain: GrainSize = .medium
    private(set) var palette: SandPalette = .sahara
    /// Sandbox only: how much of the screen is sand, 0...1 of the open area.
    var fill: Double = 0.38
    var timerSeconds = HourglassDurations.standard

    // MARK: World

    private(set) var world: SandWorld?
    private var renderer: SandRenderer?
    private(set) var container: Container?
    /// Cells the sand can occupy.
    private var openCells = 0
    private(set) var layout: SandLayout?
    private(set) var image: CGImage?
    private var mapping = MotionMapping(gravityScale: 0.25)
    private(set) var forces = SandForces(ax: 0, ay: 0.2)
    /// Lights the sand from the last direction gravity had, for when the watch lies flat.
    private var lightX: Float = 0, lightY: Float = 1

    // MARK: Time

    /// Holds the sand still, but keeps drawing it: while the hourglass is being turned over.
    var isPaused = false
    /// Frames in a row in which no grain moved. Once the sand has been still a while, and the
    /// watch is too, the simulation and the redraws stop until something changes.
    private var quietFrames = 0
    private var restingForces = SandForces(ax: 0, ay: 0)
    private static let framesBeforeSleep = 30
    /// Once it has slept a few seconds more, the render loop slows down to just checking for
    /// motion. Changing the loop's pace registers its timeline with the system afresh (for the
    /// always-on display), so it's not done for every moment the sand comes to rest in a hand
    /// that's never quite still.
    private static let framesBeforeSlowing = 210
    private var lastDate: Date?
    private var frameDebt: Double = 0
    /// Since the sand was last rendered: frames gone by, and grain moves made. And whether that
    /// render drew anything that only lasts a frame (highlights on moving grains, streaks, glints)
    /// and the light direction it used.
    private var framesSinceRender = 0
    private var movesSinceRender = 0
    private var renderFades = false
    private var renderedLight = -1
    /// Sand at rest is still rendered this often, in frames, so it keeps twinkling.
    private static let glintEvery = 6
    /// How long the last simulated frame took, in seconds.
    private var lastSimulationTime: Double = 0
    private var suspendedAt: Date?
    /// How far the hourglass has been caught up since then, and the part of a grain still owed.
    private var caughtUpAt: Date?
    private var owedGrains: Double = 0
    /// Moves a running hourglass along once a second while the always-on display shows it.
    private var dimmedTicker: Timer?

    // MARK: Pouring

    private var poured = 0
    private var introUntil: Date?
    private var pourClock: Float = 0

    // MARK: Touch

    private var finger: CGPoint?
    private var fingerPrevious: CGPoint?

    // MARK: Hourglass

    private(set) var hourglassGrains = 0
    /// Seconds of sand left in the upper bulb.
    private(set) var remaining: Double = 0
    /// What the countdown shows: the time left, or when it's run out, the time turning it over
    /// would give.
    private(set) var displayedTime: Double = 0
    /// Sand is running through the neck.
    private(set) var isTiming = false
    /// Grains per second through the neck.
    private var rate: Double { Double(max(hourglassGrains, 1)) / Double(max(timerSeconds, 1)) }
    private var flowsDownward = true
    /// What `activity` was last told, so it's only told about changes.
    private var publishedCountdown = -1
    private var publishedTiming = false

    // MARK: - Frames

    /// The sand for the frame at `date`, advanced and rendered if `live`: the screen is on and
    /// this is the frame being shown now. Anything else, such as the renders around a switch to
    /// or from the always-on display, or one with a stale date, gets the last image. So the sand
    /// only ever moves in real time, however often SwiftUI happens to draw.
    func frame(at date: Date, live: Bool) -> CGImage? {
        guard let world else { return nil }
        guard live, abs(date.timeIntervalSinceNow) < 0.5 else { return image ?? still(world) }

        let dt = lastDate.map { min(max(date.timeIntervalSince($0), 0), 0.25) } ?? 1.0 / 60
        lastDate = date
        frameDebt += isPaused ? 0 : dt * 60
        // Catch up on dropped frames, within reason; but if simulating is what makes frames late,
        // catching up would only make the next one later still, so let the sand run slow instead.
        let frames = min(Int(frameDebt), lastSimulationTime > 0.006 ? 1 : 3)
        frameDebt = frames > 0 ? min(frameDebt - Double(frames), 1) : frameDebt

        mapping.flipped = motion.screenIsFlipped
        forces = mapping.forces(for: motion.sample(at: date))
        if abs(forces.ax) + abs(forces.ay) > 0.01 {
            lightX = forces.ax
            lightY = forces.ay
        }

        if needsWaking(world) { stayAwake() }
        if quietFrames >= Self.framesBeforeSleep && image != nil {
            quietFrames += 1
            if quietFrames == Self.framesBeforeSlowing { setAsleep(true) }
            return image
        }
        // While awake, follow the forces; asleep, wake when they drift from where they settled.
        restingForces = forces

        var moves = 0
        let started = CFAbsoluteTimeGetCurrent()
        for _ in 0..<frames {
            moves += simulateFrame(world, date: date)
        }
        if frames > 0 { lastSimulationTime = (CFAbsoluteTimeGetCurrent() - started) / Double(frames) }
        if mode == .hourglass { updateTimer(world) }
        if frames > 0 {
            quietFrames = moves == 0 ? quietFrames + 1 : 0
        }

        movesSinceRender += moves
        renderIfChanged(world)
        return image
    }

    /// Renders the sand, unless it would look just as it did. On a long hourglass most frames move
    /// no grain at all, and a frame that isn't re-rendered costs SwiftUI next to nothing either.
    private func renderIfChanged(_ world: SandWorld) {
        guard let renderer else { return }
        // Which way the light falls: the renderer only cares whether it's mostly vertical, and from
        // which side.
        let light = abs(lightY) >= abs(lightX) ? (lightY >= 0 ? 0 : 1) : (lightX >= 0 ? 2 : 3)
        framesSinceRender += 1
        guard image == nil || movesSinceRender > 0 || renderFades || light != renderedLight
                || framesSinceRender >= Self.glintEvery else { return }
        renderer.render(world, gravityX: lightX, gravityY: lightY, sparkle: palette.packedSparkle,
                        stillFrames: framesSinceRender)
        image = renderer.makeImage()
        renderFades = movesSinceRender > 0 || renderer.drewStreaks || renderer.drewGlints
        renderedLight = light
        framesSinceRender = 0
        movesSinceRender = 0
    }

    /// Makes sure the next frame is rendered afresh, for when the sand changed outside a frame.
    private func renderNextFrame() {
        renderedLight = -1
    }

    /// An image of the sand as it is, without moving it.
    private func still(_ world: SandWorld) -> CGImage? {
        renderer?.render(world, gravityX: lightX, gravityY: lightY, sparkle: palette.packedSparkle)
        image = renderer?.makeImage()
        renderNextFrame()
        return image
    }

    /// Whether anything has happened that could set resting sand moving.
    private func needsWaking(_ world: SandWorld) -> Bool {
        if finger != nil || isTiming || forces.agitation > 0 { return true }
        let tolerance = mapping.gravityScale * 0.04
        if abs(forces.ax - restingForces.ax) > tolerance || abs(forces.ay - restingForces.ay) > tolerance {
            return true
        }
        if mode == .sandbox {
            let target = Int(fill * Double(openCells))
            if world.grainCount < target || world.grainCount > target + world.width / 4 { return true }
        }
        return false
    }

    /// Something outside the simulation changed the sand: make sure it's simulated and redrawn.
    private func wake() {
        stayAwake()
        renderNextFrame()
    }

    private func stayAwake() {
        quietFrames = 0
        setAsleep(false)
    }

    private func setAsleep(_ asleep: Bool) {
        guard activity.isAsleep != asleep else { return }
        // Not in the middle of drawing a frame: let the views catch up afterwards.
        Task { @MainActor in self.activity.isAsleep = asleep }
    }

    /// Returns how many cell moves happened.
    @discardableResult
    private func simulateFrame(_ world: SandWorld, date: Date) -> Int {
        switch mode {
        case .sandbox: topUp(world, date: date)
        case .hourglass: world.addGateTokens(Float(rate / 60))
        }
        let fingerVelocity = applyFinger(world)
        // Sand pushed aside by a finger has moved, whether or not it goes on moving by itself.
        if fingerVelocity != nil { renderNextFrame() }
        var impact: Float = 0
        var moves = 0
        for _ in 0..<SandWorld.stepsPerFrame {
            world.step(ax: forces.ax, ay: forces.ay, agitation: forces.agitation, drag: forces.drag)
            impact += world.lastImpact
            moves += world.lastMoves
        }
        // A finger dragged through sand shouldn't buzz like sand hitting the glass.
        if fingerVelocity == nil {
            haptics.impact(impact * 165 / Float(world.height), at: date)
        }
        return moves
    }

    // MARK: - Building the world

    /// The layout for a view of `size`, building a new world to fit if it has changed.
    func layout(for size: CGSize, scale: CGFloat, grain: GrainSize, mode: SandMode) -> SandLayout? {
        let wanted = SandLayout(size: size, scale: scale, grain: grain, mode: mode)
        guard wanted.isUsable else { return layout }
        if wanted != layout {
            self.grain = grain
            self.mode = mode
            configure(wanted, date: .now)
        }
        return layout
    }

    private func configure(_ layout: SandLayout, date: Date) {
        self.layout = layout
        let size = layout.viewSize, cellSize = layout.cellSize
        let w = layout.columns, h = layout.rows
        let container: Container
        switch mode {
        case .sandbox:
            container = .screen(width: w, height: h, cornerRadius: Float(w) * 0.21)
        case .hourglass:
            let capRoom = Float((SandDrawing.Frame.capHeight + 1) / cellSize)
            let buttonRoom: CGFloat = 52
            let maxHalf = (size.width / 2 - buttonRoom - SandDrawing.Frame.reach) / cellSize
            container = .hourglass(width: w, height: h, capRoom: capRoom, maxHalfWidth: Float(maxHalf))
        }
        let world = SandWorld(width: w, height: h, seed: UInt64.random(in: 1...UInt64.max))
        world.apply(container)
        world.parameters = .tuned(forHeight: h)
        mapping = .tuned(forHeight: h)
        self.container = container
        self.world = world
        openCells = container.interiorCount
        // Whatever the old world was timing is gone with it.
        isTiming = false
        remaining = 0
        session.stop()
        renderer = SandRenderer(width: w, height: h)
        image = nil
        poured = 0
        lastDate = nil
        wake()

        switch mode {
        case .sandbox:
            // Open with a pour: a couple of seconds of sand raining in.
            introUntil = date.addingTimeInterval(2.5)
        case .hourglass:
            introUntil = nil
            refillHourglass()
        }
    }

    /// Settles a fresh load of sand in the lower bulb.
    func refillHourglass() {
        guard let world, let container, let neck = world.neckRows else { return }
        world.apply(container)
        world.metersFlow = true
        let target = Int(Double(container.bulbCapacity()) * 0.82)
        let palette = palette
        let bandRows = max(3, world.height / 30)
        hourglassGrains = world.fill(target, rows: (neck.upperBound + 1)..<world.height) { rng, row in
            palette.makeGrain(&rng, band: row / bandRows)
        }
        isTiming = false
        remaining = 0
        session.stop()
        // The time it holds, on the cap straight away.
        updateTimer(world)
        wake()
    }

    func setPalette(_ palette: SandPalette) {
        guard palette.id != self.palette.id else { return }
        self.palette = palette
        recolor()
        wake()
    }

    /// Gives every grain a colour from the current palette, banded by height for sand art.
    private func recolor() {
        guard let world else { return }
        var rng = FastRandom(seed: UInt64.random(in: 1...UInt64.max))
        let bandRows = max(3, world.height / 30)
        for i in 0..<world.cellCount where world.kind[i] == SandWorld.grain {
            let band = (world.height - 1 - i / world.width) / bandRows
            let grain = palette.makeGrain(&rng, band: band)
            world.color[i] = grain.color
            world.grainFlags[i] = grain.flags
        }
    }

    // MARK: - Sandbox

    /// Pours sand in, or drains it out, towards the fill the Digital Crown asks for.
    private func topUp(_ world: SandWorld, date: Date) {
        let target = Int(fill * Double(openCells))
        let deficit = target - world.grainCount
        let (gx, gy) = abs(forces.ax) + abs(forces.ay) > 0.01 ? (forces.ax, forces.ay) : (lightX, lightY)
        pourClock += 1
        if deficit > 0 {
            renderNextFrame()
            let intro = introUntil.map { date < $0 } ?? false
            let streams = intro ? 3 : 1
            let perStream = min(deficit / streams + 1, max(12, world.width / 5))
            let palette = palette
            let band = poured / max(1, openCells / 30)
            for stream in 0..<streams {
                let phase = Float(stream) * 2.1
                let speed = 0.025 * (1 + Float(stream) * 0.37)
                let position = 0.5 + 0.45 * sinf(pourClock * speed + phase)
                poured += world.pour(perStream, gravityX: gx, gravityY: gy, at: position,
                                     spread: Float(world.width) * 0.05,
                                     speed: mapping.gravityScale * 4) { rng in
                    palette.makeGrain(&rng, band: band)
                }
            }
        } else if deficit < -world.width / 4 {
            world.drain(min(-deficit, world.width / 2), gravityX: gx, gravityY: gy)
            renderNextFrame()
        }
    }

    /// Empties the sandbox and pours it full again.
    func restartPour() {
        guard let world, let container else { return }
        world.apply(container)
        poured = 0
        introUntil = Date().addingTimeInterval(2.5)
        wake()
    }

    /// Double tap in the sandbox: a fountain of sand from the bottom of the screen.
    func stir() {
        guard let world else { return }
        let (gx, gy) = (lightX, lightY)
        let length = max(hypotf(gx, gy), 0.0001)
        let w = Float(world.width), h = Float(world.height)
        // Blast up from the middle of the floor, against gravity.
        let x = w / 2 + gx / length * w * 0.42
        let y = h / 2 + gy / length * h * 0.42
        world.burst(x: x, y: y, radius: w * 0.45, strength: 1.4 * mapping.gravityScale * 30)
        haptics.play(.directionUp)
        wake()
    }

    // MARK: - Touch

    /// A quick tap scatters the sand around the fingertip.
    func tap(at point: CGPoint) {
        guard let world else { return }
        let cell = cellPoint(point)
        let radius = Float(world.width) * 0.16
        world.burst(x: Float(cell.x), y: Float(cell.y), radius: radius,
                    strength: mapping.gravityScale * 22)
        haptics.play(.click)
        wake()
    }

    /// The finger is down at `point`, dragging through the sand.
    func drag(to point: CGPoint) {
        let cell = cellPoint(point)
        if finger == nil { fingerPrevious = cell }
        finger = cell
    }

    func endDrag() {
        finger = nil
        fingerPrevious = nil
    }

    /// Carves along the path the finger took since the last frame. Returns the finger's velocity
    /// in cells per step, or `nil` if no finger is down.
    private func applyFinger(_ world: SandWorld) -> CGVector? {
        guard let finger, let previous = fingerPrevious else { return nil }
        let dx = finger.x - previous.x, dy = finger.y - previous.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let radius = max(2.5, Float(world.width) * 0.03)
        let steps = max(1, Int(distance / CGFloat(radius * 0.6)))
        let per = CGFloat(SandWorld.stepsPerFrame)
        let vx = Float(dx / per), vy = Float(dy / per)
        for k in 1...steps {
            let t = CGFloat(k) / CGFloat(steps)
            world.carve(x: Float(previous.x + dx * t), y: Float(previous.y + dy * t), radius: radius,
                        fingerVX: vx, fingerVY: vy)
        }
        fingerPrevious = finger
        return CGVector(dx: CGFloat(vx), dy: CGFloat(vy))
    }

    private func cellPoint(_ point: CGPoint) -> CGPoint {
        guard let layout else { return .zero }
        return CGPoint(x: (point.x - layout.origin.x) / layout.cellSize,
                       y: (point.y - layout.origin.y) / layout.cellSize)
    }

    // MARK: - Hourglass

    /// Turns the hourglass over. The view animates the turn; this swaps the sand when it's done.
    func flip() {
        world?.rotateHalfTurn()
        haptics.play(.click)
        wake()
    }

    private func updateTimer(_ world: SandWorld) {
        guard let counts = world.bulbCounts() else { return }
        // Sand runs towards whichever end gravity favours along the hourglass.
        if abs(forces.ay) > 0.02 { flowsDownward = forces.ay > 0 }
        let upper = flowsDownward ? counts.above : counts.below
        let lower = flowsDownward ? counts.below : counts.above
        remaining = Double(upper) / rate
        // At rest, show the time that's waiting in the lower bulb, ready to be turned over.
        displayedTime = upper == 0 ? Double(lower) / rate : remaining
        let running = upper > 0 && abs(forces.ay) > 0.02
        if isTiming && upper == 0 {
            // The last grain is through.
            session.ring()
        }
        if running && !isTiming && remaining > 5 { session.start() }
        isTiming = running
        publish(countdown: Int(max(0, displayedTime).rounded(.up)), timing: isTiming)
    }

    /// Tells the views about the countdown when it changes: about once a second, rather than
    /// with every frame.
    private func publish(countdown: Int, timing: Bool) {
        guard countdown != publishedCountdown || timing != publishedTiming else { return }
        publishedCountdown = countdown
        publishedTiming = timing
        // Not in the middle of drawing a frame: let the views catch up afterwards.
        Task { @MainActor in
            self.activity.countdown = countdown
            self.activity.isTiming = timing
        }
    }

    // MARK: - Screen off and back

    /// The screen dimmed or the app left the foreground. Remember when, so the hourglass can catch
    /// up, and arrange a tap on the wrist for when its sand would run out. `showing` says the app is
    /// still on the always-on display, dimmed: a running hourglass then keeps running there, a
    /// second at a time, which is all the display shows anyway.
    func suspend(at date: Date, showing: Bool) {
        if suspendedAt == nil {
            suspendedAt = date
            caughtUpAt = date
            owedGrains = 0
            motion.stop()
            if mode == .hourglass && isTiming {
                session.scheduleAlarm(in: remaining)
            }
        }
        if showing && mode == .hourglass && isTiming && dimmedTicker == nil {
            dimmedTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.dimmedTick() }
            }
        }
    }

    func resume(at date: Date) {
        motion.start()
        stopDimmedTicker()
        defer {
            suspendedAt = nil
            caughtUpAt = nil
            lastDate = nil
            wake()
        }
        guard let suspendedAt, let world, mode == .hourglass, isTiming else { return }
        session.cancelAlarm()
        // Move the sand that would have run through while nobody was looking.
        catchUp(to: date)
        // If the alarm already went off with the screen off, don't let it ring again now.
        if let rang = session.rangAt, rang > suspendedAt { isTiming = false }
        updateTimer(world)
    }

    /// Moves the sand that ran through the neck since it was last caught up, straight from one
    /// bulb to the other.
    private func catchUp(to date: Date) {
        guard let world, let from = caughtUpAt else { return }
        let due = max(0, date.timeIntervalSince(from)) * rate + owedGrains
        let count = Int(due)
        owedGrains = due - Double(count)
        caughtUpAt = date
        world.transferThroughNeck(count, downward: flowsDownward)
    }

    /// A second on the always-on display: catch the sand up, and show it and the time left.
    private func dimmedTick() {
        guard suspendedAt != nil, mode == .hourglass, isTiming, let world, let renderer else {
            stopDimmedTicker()
            return
        }
        catchUp(to: .now)
        guard let counts = world.bulbCounts() else { return }
        renderer.render(world, gravityX: lightX, gravityY: lightY, sparkle: palette.packedSparkle)
        image = renderer.makeImage()
        renderNextFrame()
        activity.dimmedImage = image
        let upper = flowsDownward ? counts.above : counts.below
        let lower = flowsDownward ? counts.below : counts.above
        // The alarm set when the screen dimmed taps the wrist when the last grain is through.
        publish(countdown: Int((Double(upper > 0 ? upper : lower) / rate).rounded(.up)), timing: upper > 0)
        if upper == 0 { stopDimmedTicker() }
    }

    private func stopDimmedTicker() {
        dimmedTicker?.invalidate()
        dimmedTicker = nil
        activity.dimmedImage = nil
    }
}
