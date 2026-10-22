import XCTest
@testable import HourGlassCore

/// Pins the simulation's exact behaviour: scripted scenes are run from fixed seeds and the whole
/// world state is hashed along the way.
///
/// Optimisations that shouldn't change what the sand does must keep these hashes. A change that's
/// meant to alter the behaviour updates them, and says why in its commit; the behavioural tests in
/// `SandWorldTests` are what decide whether the new behaviour is still right.
final class GoldenStateTests: XCTestCase {
    func testSandboxSceneIsUnchanged() {
        XCTAssertEqual(GoldenScenes.sandbox(), GoldenScenes.Expected.sandbox)
    }

    func testHourglassSceneIsUnchanged() {
        XCTAssertEqual(GoldenScenes.hourglass(), GoldenScenes.Expected.hourglass)
    }

    func testWatchSizedSloshIsUnchanged() {
        XCTAssertEqual(GoldenScenes.slosh(), GoldenScenes.Expected.slosh)
    }

    func testRendererOutputIsUnchanged() {
        XCTAssertEqual(GoldenScenes.render(), GoldenScenes.Expected.render)
    }
}

enum GoldenScenes {
    enum Expected {
        static let sandbox: UInt64 = 18_078_610_659_436_619_740
        static let hourglass: UInt64 = 2_396_517_957_701_848_649
        static let slosh: UInt64 = 7_770_563_022_562_141_003
        static let render: UInt64 = 16_292_390_150_030_889_404
    }

    /// FNV-1a, folded over everything the simulation exposes.
    struct Hasher {
        private(set) var value: UInt64 = 0xCBF2_9CE4_8422_2325

        mutating func add(_ byte: UInt8) {
            value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }

        mutating func add(_ word: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) { add(UInt8(truncatingIfNeeded: word >> UInt32(shift))) }
        }

        mutating func add(_ int: Int) {
            add(UInt32(truncatingIfNeeded: int))
            add(UInt32(truncatingIfNeeded: int >> 32))
        }

        mutating func add(_ world: SandWorld) {
            for i in 0..<world.cellCount {
                add(world.kind[i])
                add(world.color[i])
                add(world.grainFlags[i])
                add(world.moved[i])
                add(world.velocityX[i].bitPattern)
                add(world.velocityY[i].bitPattern)
            }
            add(world.grainCount)
            add(world.frame)
            add(world.lastMoves)
            add(world.lastImpact.bitPattern)
        }
    }

    /// A different colour and the odd glint per grain, so moves show up in the hash.
    static func colors() -> (inout FastRandom) -> (color: UInt32, flags: UInt8) {
        { rng in
            let c = UInt32(truncatingIfNeeded: rng.next()) | 0xFF00_0000
            return (c, rng.below(9) == 0 ? SandWorld.sparkleFlag : 0)
        }
    }

    /// Steps `count` times, hashing the world every `every` steps.
    static func run(_ world: SandWorld, _ hasher: inout Hasher, _ count: Int, every: Int = 25,
                    ax: Float, ay: Float, agitation: Float = 0, drag: Float = 0,
                    beforeStep: (Int) -> Void = { _ in }) {
        for s in 0..<count {
            beforeStep(s)
            world.step(ax: ax, ay: ay, agitation: agitation, drag: drag)
            if s % every == every - 1 { hasher.add(world) }
        }
    }

    /// Pouring, settling, tilting past the angle of repose, a flick, bumps, glass friction, a tap,
    /// a finger drawing, draining and turning the box upside down.
    static func sandbox() -> UInt64 {
        let w = 60, h = 72
        let world = SandWorld(width: w, height: h, seed: 1)
        world.apply(.screen(width: w, height: h, cornerRadius: 10))
        world.parameters = .tuned(forHeight: h)
        var hasher = Hasher()
        let colors = colors()
        var clock: Float = 0
        run(world, &hasher, 240, ax: 0, ay: 0.16) { _ in
            clock += 1
            for stream in 0..<3 {
                let position = 0.5 + 0.45 * sinf(clock * 0.025 * (1 + Float(stream) * 0.37) + Float(stream) * 2.1)
                world.pour(4, gravityX: 0, gravityY: 0.16, at: position, spread: 3, speed: 0.6, colors: colors)
            }
        }
        run(world, &hasher, 200, ax: 0, ay: 0.16)
        run(world, &hasher, 200, ax: 0.14, ay: 0.08)
        run(world, &hasher, 8, every: 1, ax: -0.6, ay: 0.1)
        run(world, &hasher, 60, every: 5, ax: 0.05, ay: 0.12)
        run(world, &hasher, 20, every: 5, ax: 0, ay: 0.12, agitation: 0.9)
        run(world, &hasher, 120, ax: -0.03, ay: 0.02, drag: 0.02)
        world.burst(x: 30, y: 60, radius: 12, strength: 4)
        run(world, &hasher, 60, every: 5, ax: 0, ay: 0.16)
        for k in 0..<30 {
            world.carve(x: 10 + Float(k) * 1.3, y: 58 + sinf(Float(k) / 4) * 5, radius: 3,
                        fingerVX: 0.4, fingerVY: 0)
            run(world, &hasher, 1, every: 1, ax: 0, ay: 0.01)
        }
        world.drain(150, gravityX: 0, gravityY: 0.16)
        run(world, &hasher, 150, ax: 0.02, ay: -0.16)
        run(world, &hasher, 150, ax: -0.16, ay: 0.02)
        return hasher.value
    }

    /// The hourglass: settled sand turned over, metered through the neck, caught up on, turned
    /// back mid-run.
    static func hourglass() -> UInt64 {
        let w = 70, h = 84
        let container = Container.hourglass(width: w, height: h)
        let world = SandWorld(width: w, height: h, seed: 2)
        world.apply(container)
        world.parameters = .tuned(forHeight: h)
        let neck = world.neckRows!
        var hasher = Hasher()
        world.fill(Int(Double(container.bulbCapacity()) * 0.82), rows: (neck.upperBound + 1)..<h) { rng, row in
            (UInt32(truncatingIfNeeded: rng.next()) | 0xFF00_0000, row % 7 == 0 ? SandWorld.sparkleFlag : 0)
        }
        hasher.add(world)
        world.rotateHalfTurn()
        world.metersFlow = true
        let g = MotionMapping.tuned(forHeight: h).forces(for: .upright)
        run(world, &hasher, 900, ax: g.ax, ay: g.ay) { s in
            if s % 3 == 0 { world.addGateTokens(0.4) }
        }
        world.transferThroughNeck(60, downward: true)
        hasher.add(world)
        run(world, &hasher, 60, ax: g.ax * 0.3, ay: g.ay) { _ in world.addGateTokens(0.2) }
        world.rotateHalfTurn()
        run(world, &hasher, 600, ax: g.ax, ay: g.ay) { s in
            if s % 3 == 0 { world.addGateTokens(1.5, cap: 4) }
        }
        return hasher.value
    }

    /// A 46 mm watch's sandbox at medium grain, sloshed round and round as in the benchmark.
    static func slosh() -> UInt64 {
        let w = 138, h = 165
        let world = SandWorld(width: w, height: h, seed: 3)
        world.apply(.screen(width: w, height: h, cornerRadius: Float(w) * 0.21))
        world.parameters = .tuned(forHeight: h)
        let mapping = MotionMapping.tuned(forHeight: h)
        var hasher = Hasher()
        world.fill(8000, colors: { rng, _ in (UInt32(truncatingIfNeeded: rng.next()) | 0xFF00_0000, 0) })
        for s in 0..<300 {
            let r = Float(s) * 2.7 * .pi / 180
            let f = mapping.forces(for: MotionSample(gravityX: -sinf(r) * 0.9, gravityY: -cosf(r) * 0.9,
                                                     gravityZ: -0.43))
            for _ in 0..<SandWorld.stepsPerFrame { world.step(ax: f.ax, ay: f.ay, drag: f.drag) }
            if s % 10 == 9 { hasher.add(world) }
        }
        return hasher.value
    }

    /// The renderer's pixels for the sandbox scene, lit from a few directions.
    static func render() -> UInt64 {
        let w = 60, h = 72
        let world = SandWorld(width: w, height: h, seed: 4)
        world.apply(.screen(width: w, height: h, cornerRadius: 10))
        world.parameters = .tuned(forHeight: h)
        world.fill(1300) { rng, _ in
            (UInt32(truncatingIfNeeded: rng.next()) | 0xFF00_0000, rng.below(5) == 0 ? SandWorld.sparkleFlag : 0)
        }
        let renderer = SandRenderer(width: w, height: h)
        var hasher = Hasher()
        for (s, gravity) in [(Float(0), Float(0.16)), (0.15, 0.05), (-0.1, -0.12), (0.02, -0.2)].enumerated() {
            for _ in 0..<(s == 0 ? 3 : 12) { world.step(ax: gravity.0, ay: gravity.1) }
            renderer.render(world, gravityX: gravity.0, gravityY: gravity.1, sparkle: 0xFFFF_FFFF,
                            brightness: s == 3 ? 0.6 : 1)
            for i in 0..<world.cellCount { hasher.add(renderer.pixels[i]) }
        }
        return hasher.value
    }
}
