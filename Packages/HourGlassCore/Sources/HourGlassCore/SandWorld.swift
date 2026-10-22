import Foundation

/// A falling-sand world: a grid where each cell is empty, a wall, or a grain of sand with its own
/// velocity.
///
/// Grains move cell by cell along their velocity, so the momentum from a flick of the wrist carries
/// them across the screen and they pile up against the far wall. A blocked grain bounces, kicks the
/// grain it ran into, or slides to a neighbouring cell — but only to one that's "downhill" enough
/// relative to where it was heading. That last rule is what lets resting sand hold a slope (its
/// angle of repose) instead of flowing flat like water.
///
/// Units are cells and simulation steps. The world is meant to be stepped `stepsPerFrame` times
/// per 60 Hz frame: a cellular automaton moves sand one layer at a time, so it needs the extra
/// steps for avalanches and falls to happen at a believable speed for a box the size of a watch.
public final class SandWorld {
    public static let stepsPerFrame = 3

    public static let empty: UInt8 = 0
    public static let grain: UInt8 = 1
    public static let wall: UInt8 = 2

    /// Grain flag: this grain glints when it moves.
    public static let sparkleFlag: UInt8 = 1

    public struct Parameters: Sendable {
        /// Speed limit, in cells per step.
        public var maxSpeed: Float = 3.5
        /// Velocity kept from one step to the next before forces are added.
        public var drag: Float = 0.996
        /// Contacts faster than this (along the contact normal) bounce and splash; slower ones are
        /// perfectly inelastic, so resting piles stay quiet instead of jiggling.
        public var impactSpeed: Float = 1
        /// A blocked grain slower than this comes to rest.
        public var restSpeed: Float = 0.35
        /// Restitution against walls and against other grains, for impacts.
        public var wallBounce: Float = 0.35
        public var grainBounce: Float = 0.12
        /// Fraction of an impact passed on to the grain that was hit. Makes craters and splashes.
        public var splash: Float = 0.5
        /// Fraction of tangential speed lost in an impact.
        public var friction: Float = 0.2
        /// Fraction of speed lost when a grain deflects into a neighbouring cell.
        public var slideFriction: Float = 0.1
        /// Cosine of the widest angle between a grain's heading and a cell it may deflect into.
        /// About 56°: diagonals are allowed under straight-down gravity (45°), so sand piles, but
        /// a flat surface doesn't flow until it's tilted past roughly 34°.
        public var slideCosine: Float = 0.56
        /// A grain blocked by a neighbour may roll up and over it — if that's still at least this
        /// downhill (cosine to the heading) and there's room to carry on beyond. Without it a level
        /// bed tipped well past its angle of repose would jam: every surface grain waits on the one
        /// ahead, and the front one is against a wall. About 84°, so it kicks in once a level
        /// surface is tipped past ~51°.
        public var rollCosine: Float = 0.1
        /// How many times more often than its speed alone would suggest a resting grain checks
        /// whether it can move. Above 1 sand reacts a little sooner to a tilt, but the extra sideways
        /// shuffling lets holes wander instead of rising straight up, and an hourglass then drains
        /// down its sides instead of opening a crater in the middle.
        public var restingProbeBoost: Float = 1
        /// Lets a grain move straight into a cell the grain ahead of it just left.
        public var followsVacancies = true

        public init() {}

        /// The defaults tuned for a grid `height` cells tall, scaled to another height so the sand
        /// moves at the same speed across the screen whatever the grain size.
        public static func tuned(forHeight height: Int) -> Parameters {
            var p = Parameters()
            let k = max(0.5, Float(height) / 165)
            p.maxSpeed *= k
            p.impactSpeed *= k
            p.restSpeed *= k
            return p
        }
    }

    public let width: Int
    public let height: Int
    public var parameters = Parameters()

    /// Cell contents: `empty`, `grain` or `wall`.
    public let kind: UnsafeMutablePointer<UInt8>
    /// Each grain's packed RGBA colour (r in the low byte).
    public let color: UnsafeMutablePointer<UInt32>
    /// Each grain's flags, such as `sparkleFlag`.
    public let grainFlags: UnsafeMutablePointer<UInt8>
    /// The step number in which each grain last changed cell, so the renderer can light moving sand.
    public let moved: UnsafeMutablePointer<UInt8>
    public let velocityX: UnsafeMutablePointer<Float>
    public let velocityY: UnsafeMutablePointer<Float>
    /// The step number in which each grain was last updated, so a grain is moved at most once per step.
    private let stamp: UnsafeMutablePointer<UInt8>
    /// 1 for the metered cells of an hourglass neck.
    private let gate: UnsafeMutablePointer<UInt8>
    /// Scratch for each step: which rows or columns hold sand (see `Stepper.markOccupied`).
    private let occupied: UnsafeMutablePointer<UInt8>
    private let columnBits: UnsafeMutablePointer<UInt64>

    public private(set) var grainCount = 0
    /// The current step number, wrapping 1...255.
    public private(set) var frame: UInt8 = 1
    /// How hard sand hit the walls during the last step, summed over grains.
    public private(set) var lastImpact: Float = 0
    /// How many cell moves happened in the last step.
    public private(set) var lastMoves = 0
    /// The rows of the hourglass neck, if there is one.
    public private(set) var neckRows: ClosedRange<Int>?

    /// When `true`, grains may only enter the neck by spending a token (see `addGateTokens`), which
    /// is how the hourglass keeps time.
    public var metersFlow = false
    private var gateTokens: Float = 0

    private var rng: FastRandom

    public init(width: Int, height: Int, seed: UInt64 = 0x5EED_5A2D) {
        precondition(width >= 3 && height >= 3)
        self.width = width
        self.height = height
        let n = width * height
        // Padded with wall, so a neighbourhood can be read a word at a time even at the last cell.
        kind = .allocate(capacity: n + Self.padding)
        (kind + n).initialize(repeating: Self.wall, count: Self.padding)
        color = .allocate(capacity: n)
        grainFlags = .allocate(capacity: n)
        moved = .allocate(capacity: n)
        velocityX = .allocate(capacity: n)
        velocityY = .allocate(capacity: n)
        stamp = .allocate(capacity: n)
        gate = .allocate(capacity: n)
        occupied = .allocate(capacity: max(width, height))
        columnBits = .allocate(capacity: (width + 7) / 8)
        rng = FastRandom(seed: seed)
        reset(walls: nil, neck: nil)
    }

    deinit {
        kind.deallocate()
        color.deallocate()
        grainFlags.deallocate()
        moved.deallocate()
        velocityX.deallocate()
        velocityY.deallocate()
        stamp.deallocate()
        gate.deallocate()
        occupied.deallocate()
        columnBits.deallocate()
    }

    private static let padding = 8

    public var cellCount: Int { width * height }

    // MARK: - Setup

    /// Empties the world and builds the container's walls.
    public func apply(_ container: Container) {
        precondition(container.width == width && container.height == height)
        reset(walls: container.walls, neck: container.neck)
    }

    private func reset(walls: [Bool]?, neck: [Bool]?) {
        let n = cellCount
        for i in 0..<n {
            let x = i % width, y = i / width
            let border = x == 0 || y == 0 || x == width - 1 || y == height - 1
            kind[i] = border || (walls?[i] ?? false) ? Self.wall : Self.empty
            gate[i] = neck?[i] == true && !border ? 1 : 0
        }
        color.update(repeating: 0, count: n)
        grainFlags.update(repeating: 0, count: n)
        moved.update(repeating: 0, count: n)
        velocityX.update(repeating: 0, count: n)
        velocityY.update(repeating: 0, count: n)
        stamp.update(repeating: 0, count: n)
        grainCount = 0
        gateTokens = 0

        var rows: ClosedRange<Int>?
        for y in 0..<height {
            for x in 0..<width where gate[y * width + x] != 0 {
                rows = rows.map { min($0.lowerBound, y)...max($0.upperBound, y) } ?? y...y
            }
        }
        neckRows = rows
    }

    public func reseed(_ seed: UInt64) {
        rng = FastRandom(seed: seed)
    }

    // MARK: - Stepping

    /// Lets `count` more grains into the hourglass neck. Unused tokens carry over, up to half a
    /// second's worth at 60 frames a second (or `cap`), so a late straggler doesn't cost time.
    public func addGateTokens(_ count: Float, cap: Float? = nil) {
        gateTokens = min(gateTokens + count, cap ?? max(3, count * 30))
    }

    /// Advances the world one step.
    ///
    /// - Parameters:
    ///   - ax: Acceleration felt by the sand along x, in cells per step², x to the right.
    ///   - ay: Same along y, y pointing down the screen.
    ///   - agitation: Size of random velocity kicks, in cells per step, for when the watch is
    ///     bumped and the sand hops.
    ///   - drag: Speed lost per step to friction against the glass, in cells per step.
    public func step(ax: Float, ay: Float, agitation: Float = 0, drag: Float = 0) {
        frame = frame == 255 ? 1 : frame &+ 1
        var stepper = Stepper(world: self, ax: ax, ay: ay, agitation: agitation, glassDrag: drag)
        stepper.run()
        rng = stepper.rng
        gateTokens = stepper.gateTokens
        lastImpact = stepper.impact
        lastMoves = stepper.moves
    }

    /// One step's worth of work. Everything the step reads and writes is copied into a local value
    /// first, so the inner loop runs out of registers rather than going back to the world (and the
    /// runtime's exclusivity checks on its properties) for every grain.
    private struct Stepper {
        let kind: UnsafeMutablePointer<UInt8>
        let color: UnsafeMutablePointer<UInt32>
        let grainFlags: UnsafeMutablePointer<UInt8>
        let moved: UnsafeMutablePointer<UInt8>
        let velocityX: UnsafeMutablePointer<Float>
        let velocityY: UnsafeMutablePointer<Float>
        let stamp: UnsafeMutablePointer<UInt8>
        let gate: UnsafeMutablePointer<UInt8>
        let occupied: UnsafeMutablePointer<UInt8>
        let columnBits: UnsafeMutablePointer<UInt64>
        let width: Int
        let height: Int
        let p: Parameters
        let frame: UInt8
        /// The step before this one.
        let previous: UInt8
        let ax: Float, ay: Float, agitation: Float, glassDrag: Float
        let metersFlow: Bool
        var gateTokens: Float
        var rng: FastRandom
        /// What the step adds up for the world's `lastImpact` and `lastMoves`.
        var impact: Float = 0
        var moves = 0

        init(world: SandWorld, ax: Float, ay: Float, agitation: Float, glassDrag: Float) {
            kind = world.kind
            color = world.color
            grainFlags = world.grainFlags
            moved = world.moved
            velocityX = world.velocityX
            velocityY = world.velocityY
            stamp = world.stamp
            gate = world.gate
            occupied = world.occupied
            columnBits = world.columnBits
            width = world.width
            height = world.height
            p = world.parameters
            frame = world.frame
            previous = frame == 1 ? 255 : frame &- 1
            self.ax = ax
            self.ay = ay
            self.agitation = agitation
            self.glassDrag = glassDrag
            metersFlow = world.metersFlow
            gateTokens = world.gateTokens
            rng = world.rng
        }

        mutating func run() {
            let w = width, h = height
            let parity = Int(frame & 1)

            // Visit grains furthest along gravity first, so a falling column moves as one instead
            // of each grain waiting a step for the one below it. Alternate the sideways direction
            // from line to line and step to step: whichever neighbour is visited first gets first
            // go at a gap, and a fixed order would steer every rising hole the same way.
            if abs(ay) >= abs(ax) {
                markOccupied(rows: true)
                for r in 1..<(h - 1) {
                    let y = ay >= 0 ? h - 1 - r : r
                    guard occupied[y] != 0 else { continue }
                    let row = y * w
                    // Eight cells at a time where a whole block can be dealt with at once, one by
                    // one where it can't.
                    if (r + parity) & 1 == 0 {
                        var c = 1
                        while c < w - 1 {
                            if c + 8 <= w - 1 && settle(block: row + c) {
                                c += 8
                                continue
                            }
                            visit(row + c)
                            c += 1
                        }
                    } else {
                        var c = w - 2
                        while c >= 1 {
                            if c - 7 >= 1 && settle(block: row + c - 7) {
                                c -= 8
                                continue
                            }
                            visit(row + c)
                            c -= 1
                        }
                    }
                }
            } else {
                markOccupied(rows: false)
                for c in 1..<(w - 1) {
                    let x = ax >= 0 ? w - 1 - c : c
                    guard occupied[x] != 0 else { continue }
                    let forward = (c + parity) & 1 == 0
                    for r in 1..<(h - 1) {
                        visit((forward ? r : h - 1 - r) * w + x)
                    }
                }
            }
        }

        @inline(__always)
        private mutating func visit(_ i: Int) {
            if kind[i] == SandWorld.grain && stamp[i] != frame {
                update(i)
            }
        }

        /// Deals with the eight cells from `b` along the row in one go, if they need nothing or
        /// the same thing: no sand at all, or eight grains at rest that are buried, which `update`
        /// would just hold still. Returns `false` to have them visited one by one instead.
        ///
        /// Holding a buried grain still changes no cell, so what's checked here at the start holds
        /// for all eight, and the outcome is exactly that of visiting them in turn.
        @inline(__always)
        private func settle(block b: Int) -> Bool {
            let raw = UnsafeRawPointer(kind)
            let cells = raw.loadUnaligned(fromByteOffset: b, as: UInt64.self)
            let ones: UInt64 = 0x0101_0101_0101_0101
            if cells & ones == 0 { return true }
            guard cells == ones, kind[b - 1] != SandWorld.empty, kind[b + 8] != SandWorld.empty else {
                return false
            }
            // Everything around is taken: the ten cells above and below, read as two overlapping
            // words each.
            let w = width
            let around = Self.zeroBytes(raw.loadUnaligned(fromByteOffset: b - w - 1, as: UInt64.self))
                | Self.zeroBytes(raw.loadUnaligned(fromByteOffset: b - w + 1, as: UInt64.self))
                | Self.zeroBytes(raw.loadUnaligned(fromByteOffset: b + w - 1, as: UInt64.self))
                | Self.zeroBytes(raw.loadUnaligned(fromByteOffset: b + w + 1, as: UInt64.self))
            guard around == 0 else { return false }
            // None of them in flight, nor already done this step.
            let movedBytes = UnsafeRawPointer(moved).loadUnaligned(fromByteOffset: b, as: UInt64.self)
            let stampBytes = UnsafeRawPointer(stamp).loadUnaligned(fromByteOffset: b, as: UInt64.self)
            let now = ones &* UInt64(frame), before = ones &* UInt64(previous)
            guard Self.zeroBytes(movedBytes ^ now) | Self.zeroBytes(movedBytes ^ before)
                    | Self.zeroBytes(stampBytes ^ now) == 0 else { return false }
            for k in 0..<8 {
                velocityX[b + k] = 0
                velocityY[b + k] = 0
            }
            UnsafeMutableRawPointer(stamp).storeBytes(of: now, toByteOffset: b, as: UInt64.self)
            return true
        }

        /// Non-zero if any byte of `v` is zero.
        @inline(__always)
        private static func zeroBytes(_ v: UInt64) -> UInt64 {
            (v &- 0x0101_0101_0101_0101) & ~v & 0x8080_8080_8080_8080
        }

        /// Notes which rows (or columns) hold any sand as the step starts, so the empty ones can
        /// be skipped. That's exact: a grain that moves into an empty line during the step has
        /// already had its turn. Reads the grid a word at a time; empty cells and walls have no
        /// grain bit.
        private func markOccupied(rows: Bool) {
            let raw = UnsafeRawPointer(kind)
            let w = width, h = height
            let words = (w + 7) / 8
            let grainBits: UInt64 = 0x0101_0101_0101_0101
            if rows {
                for y in 1..<(h - 1) {
                    // The last word runs on into the next row, which can only keep a row in.
                    var any: UInt64 = 0
                    for k in 0..<words {
                        any |= raw.loadUnaligned(fromByteOffset: y * w + 8 * k, as: UInt64.self)
                    }
                    occupied[y] = any & grainBits != 0 ? 1 : 0
                }
            } else {
                // OR the rows together: byte x % 8 of word x / 8 then stands for column x.
                columnBits.update(repeating: 0, count: words)
                for y in 1..<(h - 1) {
                    for k in 0..<words {
                        columnBits[k] |= raw.loadUnaligned(fromByteOffset: y * w + 8 * k, as: UInt64.self)
                    }
                }
                for x in 1..<(w - 1) {
                    occupied[x] = UInt8(truncatingIfNeeded: columnBits[x / 8] >> UInt64(8 * (x % 8))) & 1
                }
            }
        }

        /// Whether all eight neighbours of `i` are taken, by sand or wall. Reads each row of three
        /// as one little-endian word, in which an empty cell is a zero byte.
        @inline(__always)
        private func surrounded(_ i: Int) -> Bool {
            let raw = UnsafeRawPointer(kind)
            let above = raw.loadUnaligned(fromByteOffset: i - width - 1, as: UInt32.self)
            let level = raw.loadUnaligned(fromByteOffset: i - 1, as: UInt32.self)
            let below = raw.loadUnaligned(fromByteOffset: i + width - 1, as: UInt32.self)
            return Self.emptyBits(above) | Self.emptyBits(level) | Self.emptyBits(below) == 0
        }

        /// Non-zero if any of the low three bytes of `v` is zero (the classic zero-byte test, with
        /// the fourth byte forced on).
        @inline(__always)
        private static func emptyBits(_ v: UInt32) -> UInt32 {
            let x = v | 0xFF00_0000
            return (x &- 0x0101_0101) & ~x & 0x8080_8080
        }

        @inline(__always)
        private mutating func update(_ start: Int) {
            let w = width
            // Sand that's been sitting still can only press on what's under it. Letting it "hit"
            // would turn the speed it gathers between moves into bounces that ripple through a
            // resting pile.
            let inFlight = moved[start] == previous || moved[start] == frame
            // Most of a pile is buried: a grain at rest with all eight neighbours taken can't go
            // anywhere this step, so skip the work. (A grain still in flight goes the long way, so
            // its impact can splash the grains it hits.)
            if !inFlight && surrounded(start) {
                velocityX[start] = 0
                velocityY[start] = 0
                stamp[start] = frame
                return
            }
            var vx = velocityX[start] * p.drag
            var vy = velocityY[start] * p.drag
            if glassDrag > 0 && (vx != 0 || vy != 0) {
                let speed = (vx * vx + vy * vy).squareRoot()
                let k = max(0, speed - glassDrag) / speed
                vx *= k
                vy *= k
            }
            vx += ax
            vy += ay
            if agitation > 0 {
                vx += rng.signedUnit() * agitation
                vy += rng.signedUnit() * agitation
            }
            let speed2 = vx * vx + vy * vy
            if speed2 > p.maxSpeed * p.maxSpeed {
                let k = p.maxSpeed / speed2.squareRoot()
                vx *= k
                vy *= k
            }

            var i = start
            let absX = abs(vx), absY = abs(vy)
            let m = max(absX, absY)
            if m > 0.0001 {
                // Move m cells this step on average: the whole part always, the fraction by chance.
                // Each move is one cell along x, y or a diagonal, picked so the expected
                // displacement matches the velocity — shallow angles don't get rounded away.
                var steps = Int(m)
                let fraction = m - Float(steps)
                if rng.unit() < (inFlight ? fraction : fraction * p.restingProbeBoost) { steps += 1 }
                let chanceX = absX / m, chanceY = absY / m
                let stepX = vx < 0 ? -1 : 1
                let stepY = vy < 0 ? -1 : 1
                if steps == 0 && p.followsVacancies {
                    // If the grain ahead just moved off, follow it now rather than whenever the
                    // dice say so: that way a column or an overhang falls as one piece instead of
                    // crumbling a layer at a time.
                    let ahead = i + (absX >= absY ? stepX : stepY * w)
                    if kind[ahead] == SandWorld.empty && (moved[ahead] == frame || moved[ahead] == previous) {
                        steps = 1
                    }
                }
                var n = 0
                while n < steps {
                    n += 1
                    let dx = chanceX >= 1 || rng.unit() < chanceX ? stepX : 0
                    let dy = chanceY >= 1 || rng.unit() < chanceY ? stepY : 0
                    let target = i + dx + dy * w
                    if enter(from: i, to: target) {
                        shift(i, to: target)
                        i = target
                        continue
                    }

                    let headingX = vx, headingY = vy
                    // A grain blocked by one moving the same way just falls in behind it, the way
                    // a stream of sand stays a stream; only sand that's (nearly) still deflects it.
                    let speed2 = vx * vx + vy * vy
                    let following = speed2 > 0.25 * p.impactSpeed * p.impactSpeed
                        && kind[target] == SandWorld.grain
                        && (moved[target] == frame || moved[target] == previous)
                        && velocityX[target] * vx + velocityY[target] * vy > 0.3 * speed2
                    let impact = collide(target, dx, dy, inFlight || n > 1, &vx, &vy)
                    // What a deflected grain carries on with: after a hard landing only what
                    // survived the impact, otherwise its whole speed, so avalanches keep rolling.
                    let carried = impact
                        ? (vx * vx + vy * vy).squareRoot()
                        : (headingX * headingX + headingY * headingY).squareRoot()
                    if let (cell, ux, uy, rolled) = deflect(from: i, dx, dy, headingX, headingY,
                                                             rollOnly: following) {
                        shift(i, to: cell)
                        i = cell
                        if rolled {
                            // Having climbed over a neighbour, carry on along the top of it.
                            let speed = carried * (1 - p.slideFriction)
                            let k: Float = dx != 0 && dy != 0 ? 0.707_106_8 : 1
                            vx = Float(dx) * k * speed
                            vy = Float(dy) * k * speed
                        } else {
                            // Keep sliding along the new direction, so avalanches pick up speed.
                            let speed = carried * (1 - p.slideFriction)
                            vx = ux * speed
                            vy = uy * speed
                        }
                    } else if kind[target] == SandWorld.wall, let cell = slip(from: i, dx, dy, headingX, headingY) {
                        shift(i, to: cell)
                        i = cell
                        vx = 0
                        vy = 0
                    } else if !inFlight || vx * vx + vy * vy < p.restSpeed * p.restSpeed {
                        // Static friction: sand that was sitting still and has nowhere downhill
                        // enough to go stays put, whatever sideways speed it gathered meanwhile.
                        vx = 0
                        vy = 0
                    }
                    break
                }
            }
            velocityX[i] = vx
            velocityY[i] = vy
            stamp[i] = frame
        }

        /// Whether a grain at `from` may move into `to`, spending a neck token if it has to.
        @inline(__always)
        private mutating func enter(from: Int, to: Int) -> Bool {
            guard kind[to] == SandWorld.empty else { return false }
            if metersFlow && gate[to] != 0 && gate[from] == 0 {
                // Straight in, unless no grain is waiting straight above the neck cell. Otherwise
                // the grains sliding down the glass beside the neck get there first, and the hole
                // each one leaves climbs up along the glass: the hourglass drains down its sides
                // instead of opening a crater in the middle. (And without the exception, the last
                // grains would sit on the ledge beside the neck for ever.)
                let step = to - from
                if step != width && step != -width && step != 1 && step != -1 {
                    let sideways = step > 0 ? (step == width + 1 ? 1 : -1) : (step == -width + 1 ? 1 : -1)
                    let straightAbove = to - (step - sideways)
                    if kind[straightAbove] == SandWorld.grain { return false }
                }
                guard gateTokens >= 1 else { return false }
                gateTokens -= 1
            }
            return true
        }

        /// Velocity response to being blocked moving by (dx, dy). Only a grain that's `moving` can
        /// bounce or splash; otherwise the contact just stops it closing in.
        /// Returns whether it was an impact rather than a resting contact.
        @inline(__always)
        private mutating func collide(_ target: Int, _ dx: Int, _ dy: Int, _ moving: Bool,
                                      _ vx: inout Float, _ vy: inout Float) -> Bool {
            var nx = Float(dx), ny = Float(dy)
            if dx != 0 && dy != 0 {
                nx *= 0.707_106_8
                ny *= 0.707_106_8
            }
            let vn = vx * nx + vy * ny
            // Work relative to what was hit: a wall is still, a grain may be moving too.
            let isGrain = kind[target] == SandWorld.grain
            let other = isGrain ? velocityX[target] * nx + velocityY[target] * ny : 0
            let closing = vn - other
            guard closing > 0 else { return false }
            if closing <= p.impactSpeed || !moving {
                // Resting contact: just stop closing in.
                vx -= closing * nx
                vy -= closing * ny
                return false
            }
            let bounce: Float
            if isGrain {
                bounce = p.grainBounce
                let kick = closing * p.splash
                velocityX[target] += kick * nx
                velocityY[target] += kick * ny
            } else {
                bounce = p.wallBounce
                if kind[target] == SandWorld.wall { impact += closing - p.impactSpeed }
            }
            let keep = 1 - p.friction
            let tx = vx - vn * nx, ty = vy - vn * ny
            let normal = other - bounce * closing
            vx = tx * keep + normal * nx
            vy = ty * keep + normal * ny
            return true
        }

        /// After being blocked moving by (dx, dy), tries the two neighbouring directions 45° either
        /// side, most downhill first, as long as they're within the slide angle of the heading.
        /// Returns the cell moved into, the unit direction of the move, and whether it was a
        /// roll-over.
        @inline(__always)
        private mutating func deflect(from i: Int, _ dx: Int, _ dy: Int, _ hx: Float, _ hy: Float,
                                      rollOnly: Bool) -> (Int, Float, Float, Bool)?
        {
            let speed = (hx * hx + hy * hy).squareRoot()
            guard speed > 0.0001 else { return nil }
            let ux = hx / speed, uy = hy / speed

            let ax, ay, bx, by: Int
            if dx != 0 && dy != 0 {
                (ax, ay, bx, by) = (dx, 0, 0, dy)
            } else if dx != 0 {
                (ax, ay, bx, by) = (dx, 1, dx, -1)
            } else {
                (ax, ay, bx, by) = (1, dy, -1, dy)
            }
            let sa: Float = ax != 0 && ay != 0 ? 0.707_106_8 : 1
            let sb: Float = bx != 0 && by != 0 ? 0.707_106_8 : 1
            let da = (Float(ax) * ux + Float(ay) * uy) * sa
            let db = (Float(bx) * ux + Float(by) * uy) * sb

            let aFirst = abs(da - db) < 0.04 ? rng.coinFlip() : da > db
            let slide = p.slideCosine
            // After a straight-on block, the less downhill diagonal climbs over what's in the way.
            let roll = (dx == 0 || dy == 0) && kind[i + dx + dy * width] == SandWorld.grain
                ? p.rollCosine : slide
            if rollOnly && roll >= slide { return nil }
            for pass in 0..<2 {
                let useA = (pass == 0) == aFirst
                let d = useA ? da : db
                guard d >= (pass == 0 ? slide : min(slide, roll)) else { continue }
                // Behind a moving grain, only climbing over it is allowed: that thickens a flowing
                // layer, while sliding aside would scatter a falling stream.
                if rollOnly && d >= slide { continue }
                let cx = useA ? ax : bx, cy = useA ? ay : by
                let cell = i + cx + cy * width
                // A grain only rolls over a neighbour if it can carry on along the top of it;
                // otherwise rolling would slowly steepen slopes that are already stable.
                if d < slide && kind[cell + dx + dy * width] != SandWorld.empty { continue }
                if enter(from: i, to: cell) {
                    let s = useA ? sa : sb
                    return (cell, Float(cx) * s, Float(cy) * s, d < slide)
                }
            }
            return nil
        }

        /// Glass is slicker than sand. A grain sitting on a ledge of the glass staircase (blocked
        /// straight ahead by wall, with no open diagonal) may step sideways if the glass falls away
        /// just beyond; sand-on-sand never does this, so piles keep their slopes, and a level floor
        /// never qualifies. Without it a thin skin of sand clings to shallow glass for ever, and an
        /// hourglass never quite runs out.
        @inline(__always)
        private mutating func slip(from i: Int, _ dx: Int, _ dy: Int, _ hx: Float, _ hy: Float) -> Int? {
            guard dx == 0 || dy == 0 else { return nil }
            let ahead = dx + dy * width
            let side = dx == 0 ? 1 : width
            // Try the side gravity leans towards first.
            let lean = dx == 0 ? hx : hy
            let first = lean > 0 || (lean == 0 && rng.coinFlip()) ? side : -side
            if let cell = slip(from: i, by: first, ahead: ahead) { return cell }
            return slip(from: i, by: -first, ahead: ahead)
        }

        /// One side of `slip`: a step of `d` onto glass that falls away beyond it.
        @inline(__always)
        private mutating func slip(from i: Int, by d: Int, ahead: Int) -> Int? {
            let next = i + d
            guard kind[next] == SandWorld.empty, kind[next + ahead] == SandWorld.wall,
                  kind[next + d + ahead] == SandWorld.empty else { return nil }
            return enter(from: i, to: next) ? next : nil
        }

        /// Moves a grain's contents (not its velocity, which `update` writes at the end) to an
        /// empty cell.
        @inline(__always)
        private mutating func shift(_ from: Int, to: Int) {
            kind[to] = SandWorld.grain
            kind[from] = SandWorld.empty
            color[to] = color[from]
            grainFlags[to] = grainFlags[from]
            moved[to] = frame
            // On an empty cell, `moved` records when it was vacated (see the follow rule in `update`).
            moved[from] = frame
            moves += 1
        }
    }

    /// Moves a whole grain, velocity included, to an empty cell.
    private func relocate(_ from: Int, to: Int) {
        kind[to] = Self.grain
        kind[from] = Self.empty
        color[to] = color[from]
        grainFlags[to] = grainFlags[from]
        moved[to] = frame
        moved[from] = frame
        lastMoves += 1
        velocityX[to] = velocityX[from]
        velocityY[to] = velocityY[from]
        stamp[to] = stamp[from]
        velocityX[from] = 0
        velocityY[from] = 0
    }

    // MARK: - Adding and removing sand

    @discardableResult
    public func addGrain(at index: Int, color c: UInt32, flags: UInt8 = 0,
                         vx: Float = 0, vy: Float = 0) -> Bool {
        guard index >= 0, index < cellCount, kind[index] == Self.empty else { return false }
        kind[index] = Self.grain
        color[index] = c
        grainFlags[index] = flags
        velocityX[index] = vx
        velocityY[index] = vy
        moved[index] = frame
        grainCount += 1
        return true
    }

    @discardableResult
    public func removeGrain(at index: Int) -> Bool {
        guard index >= 0, index < cellCount, kind[index] == Self.grain else { return false }
        kind[index] = Self.empty
        velocityX[index] = 0
        velocityY[index] = 0
        grainCount -= 1
        return true
    }

    /// Drops up to `count` grains in at the edge opposite gravity, already falling.
    ///
    /// - Parameters:
    ///   - position: Where along that edge the stream comes in, from 0 to 1 (left to right, or top
    ///     to bottom when gravity is mostly sideways). `nil` scatters the grains along the whole edge.
    ///   - spread: The stream's half-width in cells.
    ///   - colors: Supplies each new grain's colour and flags.
    @discardableResult
    public func pour(_ count: Int, gravityX gx: Float, gravityY gy: Float, at position: Float? = nil,
                     spread: Float = 2.5, speed: Float = 1,
                     colors: (inout FastRandom) -> (color: UInt32, flags: UInt8)) -> Int {
        let length = hypotf(gx, gy)
        let (ux, uy) = length > 0.0001 ? (gx / length, gy / length) : (Float(0), Float(1))
        let vertical = abs(uy) >= abs(ux)
        let span = vertical ? width : height
        func line() -> Int {
            guard let position else { return 1 + rng.below(span - 2) }
            let centre = 1 + position * Float(span - 3)
            return max(1, min(span - 2, Int(centre + rng.signedUnit() * spread)))
        }
        var added = 0
        var attempts = 0
        while added < count && attempts < count * 4 {
            attempts += 1
            // Pick a line across the flow, then find an open cell near the upstream edge.
            var cell = -1
            if vertical {
                let x = line()
                let depth = rng.below(3)
                var found = 0
                for r in 0..<height {
                    let i = (uy >= 0 ? r : height - 1 - r) * width + x
                    if kind[i] == Self.wall { if found > 0 { break } else { continue } }
                    if found == depth { cell = kind[i] == Self.empty ? i : -1; break }
                    found += 1
                }
            } else {
                let y = line()
                let depth = rng.below(3)
                var found = 0
                for c in 0..<width {
                    let i = y * width + (ux >= 0 ? c : width - 1 - c)
                    if kind[i] == Self.wall { if found > 0 { break } else { continue } }
                    if found == depth { cell = kind[i] == Self.empty ? i : -1; break }
                    found += 1
                }
            }
            guard cell >= 0 else { continue }
            let grain = colors(&rng)
            let jitter = 1 + rng.signedUnit() * 0.3
            if addGrain(at: cell, color: grain.color, flags: grain.flags,
                        vx: ux * speed * jitter, vy: uy * speed * jitter) {
                added += 1
            }
        }
        return added
    }

    /// Fills open cells from the far end along +y (or −y), row by row, with settled sand.
    /// `rows` limits the fill to part of the grid, such as one bulb of the hourglass.
    @discardableResult
    public func fill(_ count: Int, downward: Bool = true, rows: Range<Int>? = nil,
                     colors: (inout FastRandom, Int) -> (color: UInt32, flags: UInt8)) -> Int {
        let range = rows ?? 0..<height
        var added = 0
        var row = 0
        for r in 0..<range.count where added < count {
            let y = downward ? range.upperBound - 1 - r : range.lowerBound + r
            var open: [Int] = []
            for x in 0..<width where kind[y * width + x] == Self.empty { open.append(y * width + x) }
            // Shuffle so a partly filled top row is ragged rather than filled from one side.
            for k in stride(from: open.count - 1, to: 0, by: -1) {
                open.swapAt(k, rng.below(k + 1))
            }
            for i in open where added < count {
                let grain = colors(&rng, row)
                if addGrain(at: i, color: grain.color, flags: grain.flags) { added += 1 }
            }
            if !open.isEmpty { row += 1 }
        }
        return added
    }

    /// Removes up to `count` grains from the top of the sand, as seen against gravity.
    @discardableResult
    public func drain(_ count: Int, gravityX gx: Float, gravityY gy: Float) -> Int {
        var removed = 0
        let vertical = abs(gy) >= abs(gx)
        let lines = vertical ? height : width
        let span = vertical ? width : height
        let offset = rng.below(span)
        for l in 0..<lines where removed < count {
            let line = vertical ? (gy >= 0 ? l : height - 1 - l) : (gx >= 0 ? l : width - 1 - l)
            for s in 0..<span where removed < count {
                let along = (s + offset) % span
                let i = vertical ? line * width + along : along * width + line
                if removeGrain(at: i) { removed += 1 }
            }
        }
        return removed
    }

    // MARK: - Touch

    /// Blasts sand away from a point, strongest at the centre.
    public func burst(x: Float, y: Float, radius: Float, strength: Float) {
        forEachGrain(nearX: x, y: y, radius: radius) { i, dx, dy, distance in
            let falloff = 1 - distance / radius
            let k = strength * falloff * falloff / max(distance, 0.5)
            velocityX[i] += dx * k + rng.signedUnit() * strength * 0.15
            velocityY[i] += dy * k + rng.signedUnit() * strength * 0.15
        }
    }

    /// Pushes sand out of a disc, as a fingertip dragged through it would, leaving a clear trail.
    /// Each grain goes to the free cell nearest where it would leave the disc, so sand banks up in
    /// front of a moving finger. (fvx, fvy) is the finger's velocity in cells per step.
    public func carve(x: Float, y: Float, radius: Float, fingerVX fvx: Float, fingerVY fvy: Float) {
        var inside: [(index: Int, rimX: Float, rimY: Float)] = []
        forEachGrain(nearX: x, y: y, radius: radius) { i, dx, dy, distance in
            let d = max(distance, 0.01)
            inside.append((i, x + dx / d * radius, y + dy / d * radius))
        }
        guard !inside.isEmpty else { return }

        // Free cells in a ring around the disc.
        let reach = radius + 12
        var free: [Int] = []
        let minX = max(1, Int(x - reach)), maxX = min(width - 2, Int(x + reach))
        let minY = max(1, Int(y - reach)), maxY = min(height - 2, Int(y + reach))
        if minX <= maxX && minY <= maxY {
            for cy in minY...maxY {
                for cx in minX...maxX where kind[cy * width + cx] == Self.empty {
                    let dx = Float(cx) + 0.5 - x, dy = Float(cy) + 0.5 - y
                    let d2 = dx * dx + dy * dy
                    if d2 >= radius * radius && d2 < reach * reach { free.append(cy * width + cx) }
                }
            }
        }

        for grain in inside {
            var best = -1
            var bestDistance = Float.infinity
            for (n, cell) in free.enumerated() where cell >= 0 {
                let dx = Float(cell % width) + 0.5 - grain.rimX
                let dy = Float(cell / width) + 0.5 - grain.rimY
                let d2 = dx * dx + dy * dy
                if d2 < bestDistance { bestDistance = d2; best = n }
            }
            guard best >= 0 else { break }
            let cell = free[best]
            free[best] = -1
            relocate(grain.index, to: cell)
            let dx = Float(cell % width) + 0.5 - x, dy = Float(cell / width) + 0.5 - y
            let d = max((dx * dx + dy * dy).squareRoot(), 0.01)
            velocityX[cell] = dx / d * 0.5 + fvx * 0.5
            velocityY[cell] = dy / d * 0.5 + fvy * 0.5
        }
    }

    private func forEachGrain(nearX x: Float, y: Float, radius: Float,
                              _ body: (Int, Float, Float, Float) -> Void) {
        let minX = max(1, Int(x - radius)), maxX = min(width - 2, Int(x + radius))
        let minY = max(1, Int(y - radius)), maxY = min(height - 2, Int(y + radius))
        guard minX <= maxX, minY <= maxY else { return }
        for cy in minY...maxY {
            for cx in minX...maxX {
                let i = cy * width + cx
                guard kind[i] == Self.grain else { continue }
                let dx = Float(cx) + 0.5 - x, dy = Float(cy) + 0.5 - y
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance < radius { body(i, dx, dy, distance) }
            }
        }
    }

    // MARK: - Hourglass

    /// Turns the contents upside down. Only meaningful for containers that are symmetric under a
    /// half turn, like the hourglass, whose walls then land exactly on themselves.
    public func rotateHalfTurn() {
        var a = 0, b = cellCount - 1
        while a < b {
            swap(&kind[a], &kind[b])
            swap(&color[a], &color[b])
            swap(&grainFlags[a], &grainFlags[b])
            swap(&moved[a], &moved[b])
            let (ax, ay) = (velocityX[a], velocityY[a])
            velocityX[a] = -velocityX[b]
            velocityY[a] = -velocityY[b]
            velocityX[b] = -ax
            velocityY[b] = -ay
            a += 1
            b -= 1
        }
        if a == b {
            velocityX[a] = -velocityX[a]
            velocityY[a] = -velocityY[a]
        }
    }

    /// Grains in rows `rows` (clamped to the grid).
    public func grainCount(inRows rows: Range<Int>) -> Int {
        let lo = max(0, rows.lowerBound), hi = min(height, rows.upperBound)
        guard lo < hi else { return 0 }
        var count = 0
        for i in (lo * width)..<(hi * width) where kind[i] == Self.grain { count += 1 }
        return count
    }

    /// Grains above and below the neck, in screen terms (smaller y is "above").
    public func bulbCounts() -> (above: Int, below: Int)? {
        guard let neck = neckRows else { return nil }
        return (grainCount(inRows: 0..<neck.lowerBound),
                grainCount(inRows: (neck.upperBound + 1)..<height))
    }

    /// Moves up to `count` grains straight from the surface of the upper bulb to the surface of
    /// the lower one, for catching up on time that passed while the screen was off.
    /// `downward` says which way the sand is flowing in screen terms.
    @discardableResult
    public func transferThroughNeck(_ count: Int, downward: Bool) -> Int {
        guard let neck = neckRows, count > 0 else { return 0 }
        let upper = 0..<neck.lowerBound, lower = (neck.upperBound + 1)..<height
        let sourceRows = downward ? Array(upper) : Array(lower.reversed())
        let targetRows = downward ? Array(lower.reversed()) : Array(upper)
        var room = 0
        for y in targetRows {
            for x in 0..<width where kind[y * width + x] == Self.empty { room += 1 }
        }
        let count = min(count, room)
        guard count > 0 else { return 0 }

        // Take from the upper bulb, starting at its free surface.
        var taken: [(UInt32, UInt8)] = []
        outer: for y in sourceRows {
            for x in 0..<width {
                let i = y * width + x
                if kind[i] == Self.grain {
                    taken.append((color[i], grainFlags[i]))
                    removeGrain(at: i)
                    if taken.count == count { break outer }
                }
            }
        }
        // Settle them onto the lower bulb, from its far end.
        var next = 0
        outer2: for y in targetRows {
            for x in 0..<width where next < taken.count {
                let i = y * width + x
                if kind[i] == Self.empty {
                    addGrain(at: i, color: taken[next].0, flags: taken[next].1)
                    next += 1
                }
            }
            if next == taken.count { break outer2 }
        }
        return next
    }

    /// The stored velocity of the grain at `index`.
    public func velocity(at index: Int) -> (x: Float, y: Float) {
        (velocityX[index], velocityY[index])
    }
}
