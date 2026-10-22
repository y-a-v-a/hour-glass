import XCTest
@testable import HourGlassCore

final class SandWorldTests: XCTestCase {
    private let grainColor: (inout FastRandom) -> (color: UInt32, flags: UInt8) = { _ in (0xFF33_6699, 0) }

    private func screenWorld(width: Int = 60, height: Int = 72) -> (SandWorld, Container) {
        let container = Container.screen(width: width, height: height, cornerRadius: 10)
        let world = SandWorld(width: width, height: height)
        world.apply(container)
        world.parameters = .tuned(forHeight: height)
        return (world, container)
    }

    private func countCells(_ world: SandWorld, _ kind: UInt8) -> Int {
        (0..<world.cellCount).filter { world.kind[$0] == kind }.count
    }

    /// Pours sand in and lets it come to rest under straight-down gravity.
    private func settle(_ world: SandWorld, grains: Int, ay: Float = 0.16) {
        var poured = 0
        var steps = 0
        while poured < grains && steps < 2000 {
            poured += world.pour(min(20, grains - poured), gravityX: 0, gravityY: 1, colors: grainColor)
            world.step(ax: 0, ay: ay)
            steps += 1
        }
        for _ in 0..<600 { world.step(ax: 0, ay: ay) }
    }

    func testGrainsAndWallsAreConservedUnderViolentMotion() {
        let (world, container) = screenWorld()
        settle(world, grains: 900)
        let walls = countCells(world, SandWorld.wall)
        XCTAssertEqual(walls, container.walls.filter { $0 }.count)
        var rng = FastRandom(seed: 42)
        for step in 0..<1500 {
            let ax = rng.signedUnit() * 0.8, ay = rng.signedUnit() * 0.8
            world.step(ax: ax, ay: ay, agitation: step % 50 == 0 ? 1.5 : 0)
            if step % 200 == 0 {
                world.burst(x: 30, y: 40, radius: 12, strength: 5)
                world.carve(x: 20 + Float(step % 20), y: 50, radius: 4, fingerVX: 1, fingerVY: 0)
            }
        }
        XCTAssertEqual(world.grainCount, 900)
        XCTAssertEqual(countCells(world, SandWorld.grain), 900)
        XCTAssertEqual(countCells(world, SandWorld.wall), walls)
    }

    func testTinyAndOddSizedGridsKeepTheirSand() {
        // The engine reads the grid eight cells at a time; sizes either side of a multiple of eight,
        // and grids too small for a block at all, take the edge cases.
        for (w, h) in [(3, 3), (4, 7), (8, 8), (9, 9), (10, 17), (15, 16), (16, 15), (17, 23), (31, 9)] {
            let world = SandWorld(width: w, height: h, seed: UInt64(w * 100 + h))
            let container = Container.screen(width: w, height: h, cornerRadius: Float(min(w, h)) * 0.2)
            world.apply(container)
            world.parameters = .tuned(forHeight: h)
            let grains = world.fill(container.interiorCount / 2) { _, _ in (0xFFFF_FFFF, 1) }
            let walls = countCells(world, SandWorld.wall)
            var rng = FastRandom(seed: 5)
            for s in 0..<600 {
                world.step(ax: rng.signedUnit() * 0.6, ay: rng.signedUnit() * 0.6,
                           agitation: s % 50 < 3 ? 1 : 0, drag: s % 100 < 30 ? 0.02 : 0)
                if s == 300 { world.burst(x: Float(w) / 2, y: Float(h) / 2, radius: Float(w), strength: 3) }
            }
            XCTAssertEqual(world.grainCount, grains, "\(w)x\(h)")
            XCTAssertEqual(countCells(world, SandWorld.grain), grains, "\(w)x\(h)")
            XCTAssertEqual(countCells(world, SandWorld.wall), walls, "\(w)x\(h)")
        }
    }

    func testSettledSandIsSupportedAndGoesQuiet() {
        let (world, _) = screenWorld()
        settle(world, grains: 800)
        XCTAssertEqual(world.grainCount, 800)
        // Nothing hangs in mid-air: every grain has something directly beneath it.
        for i in 0..<world.cellCount where world.kind[i] == SandWorld.grain {
            XCTAssertNotEqual(world.kind[i + world.width], SandWorld.empty, "grain at \(i) floats")
        }
        // And the pile stops moving altogether, so a still watch costs no redraw churn.
        var moves = 0
        for _ in 0..<120 {
            world.step(ax: 0, ay: 0.16)
            moves += world.lastMoves
        }
        XCTAssertEqual(moves, 0)
    }

    func testFlatBedHoldsAGentleTiltButAvalanchesWhenSteep() {
        /// Cell moves in the first `steps` steps after tilting a flat, settled bed by `degrees`.
        func moves(tilting degrees: Float, steps: Int, skipping skip: Int = 0) -> Int {
            let (world, _) = screenWorld()
            world.fill(1200) { _, _ in (0xFFFF_FFFF, 0) }
            let r = degrees * .pi / 180
            let ax = sinf(r) * 0.1, ay = cosf(r) * 0.1
            for _ in 0..<skip { world.step(ax: ax, ay: ay) }
            var total = 0
            for _ in 0..<steps {
                world.step(ax: ax, ay: ay)
                total += world.lastMoves
            }
            return total
        }
        XCTAssertEqual(moves(tilting: 0, steps: 120), 0, "a flat bed is already at rest")
        XCTAssertEqual(moves(tilting: 20, steps: 120), 0, "a 20° tilt is inside the angle of repose")
        XCTAssertGreaterThan(moves(tilting: 60, steps: 120), 2000, "a 60° tilt should avalanche")
        XCTAssertEqual(moves(tilting: 60, steps: 60, skipping: 1800), 0, "and then come to rest")
    }

    func testFlickThrowsSandAcrossTheScreen() {
        let (world, _) = screenWorld()
        // A heap in the middle of the floor, with room on both sides.
        for y in 52..<70 {
            for x in 22..<38 { world.addGrain(at: y * world.width + x, color: 0xFFFF_FFFF) }
        }
        for _ in 0..<200 { world.step(ax: 0, ay: 0.1) }
        func centreOfMassX() -> Float {
            var sum: Float = 0
            for i in 0..<world.cellCount where world.kind[i] == SandWorld.grain {
                sum += Float(i % world.width)
            }
            return sum / Float(world.grainCount)
        }
        let before = centreOfMassX()
        for _ in 0..<8 { world.step(ax: -0.5, ay: 0.1) }
        for _ in 0..<20 { world.step(ax: 0, ay: 0.1) }
        XCTAssertLessThan(centreOfMassX(), before - 4, "momentum should carry the sand left")
        XCTAssertEqual(world.grainCount, 288)
    }

    func testHourglassIsSymmetricUnderAHalfTurn() {
        for (w, h) in [(138, 165), (104, 124), (208, 248), (93, 111)] {
            let c = Container.hourglass(width: w, height: h)
            let n = w * h
            for i in 0..<n {
                XCTAssertEqual(c.walls[i], c.walls[n - 1 - i], "\(w)x\(h) wall \(i)")
                XCTAssertEqual(c.neck[i], c.neck[n - 1 - i], "\(w)x\(h) neck \(i)")
            }
            // The neck is open, so sand can get through.
            XCTAssertGreaterThan(c.neck.filter { $0 }.count, 3)
        }
    }

    func testRotatingTheHourglassKeepsWallsInPlace() {
        let container = Container.hourglass(width: 70, height: 84)
        let world = SandWorld(width: 70, height: 84)
        world.apply(container)
        let neck = world.neckRows!
        world.fill(400, rows: (neck.upperBound + 1)..<84) { rng, _ in (0xFFFF_FFFF, 0) }
        let walls = (0..<world.cellCount).map { world.kind[$0] == SandWorld.wall }
        world.rotateHalfTurn()
        XCTAssertEqual((0..<world.cellCount).map { world.kind[$0] == SandWorld.wall }, walls)
        let counts = world.bulbCounts()!
        XCTAssertEqual(counts.above, 400)
        XCTAssertEqual(counts.below, 0)
    }

    func testNeckMetersTheFlow() {
        let container = Container.hourglass(width: 70, height: 84)
        let world = SandWorld(width: 70, height: 84)
        world.apply(container)
        world.parameters = .tuned(forHeight: 84)
        let neck = world.neckRows!
        world.fill(500, downward: false, rows: 0..<neck.lowerBound) { _, _ in (0xFFFF_FFFF, 0) }
        world.metersFlow = true
        // Half a grain per step: 300 steps should let about 150 through, and never more.
        for _ in 0..<300 {
            world.addGateTokens(0.5)
            world.step(ax: 0, ay: 0.16)
        }
        for _ in 0..<60 { world.step(ax: 0, ay: 0.16) }
        let counts = world.bulbCounts()!
        XCTAssertLessThanOrEqual(counts.below, 152)
        XCTAssertGreaterThan(counts.below, 120, "the neck should pass what the tokens allow")
        XCTAssertEqual(world.grainCount, 500)
    }

    func testHourglassDrainsFromTheMiddle() {
        // Holes left by grains going through the neck should rise up the middle and open a crater
        // on top, as in a real hourglass, rather than the sand running down the glass and leaving
        // a peak in the middle.
        var depth: Float = 0
        for seed in 1...4 {
            let w = 60, h = 72
            let container = Container.hourglass(width: w, height: h)
            let world = SandWorld(width: w, height: h, seed: UInt64(seed))
            world.apply(container)
            world.parameters = .tuned(forHeight: h)
            world.metersFlow = true
            let neck = world.neckRows!
            world.fill(500, rows: 0..<neck.lowerBound) { _, _ in (0xFFFF_FFFF, 0) }
            let g = MotionMapping.tuned(forHeight: h).forces(for: .upright)
            for _ in 0..<30 { for _ in 0..<3 { world.step(ax: g.ax, ay: g.ay) } }
            for _ in 0..<100 {
                world.addGateTokens(1)
                for _ in 0..<3 { world.step(ax: g.ax, ay: g.ay) }
            }
            func surface(_ x: Int) -> Float { Float((0..<h).first { world.kind[$0 * w + x] == SandWorld.grain } ?? h) }
            depth += (surface(29) + surface(30)) / 2 - (surface(17) + surface(42)) / 2
        }
        XCTAssertGreaterThan(depth / 4, 2, "the middle of the top surface should sink lowest")
    }

    func testHourglassKeepsTime() {
        // A 46 mm watch at medium grain: 138 × 126 cells below the top bar.
        for seconds in [30.0, 60.0] {
            let w = 138, h = 126
            let container = Container.hourglass(width: w, height: h, capRoom: 10.3, maxHalfWidth: 29.6)
            let world = SandWorld(width: w, height: h)
            world.apply(container)
            world.parameters = .tuned(forHeight: h)
            world.metersFlow = true
            let neck = world.neckRows!
            let total = world.fill(Int(Double(container.bulbCapacity()) * 0.82), downward: false,
                                   rows: 0..<neck.lowerBound) { _, _ in (0xFFFF_FFFF, 0) }
            let rate = Double(total) / seconds
            let g = MotionMapping.tuned(forHeight: h).forces(for: .upright)
            var frames = 0
            while world.grainCount(inRows: 0..<neck.lowerBound) > 0 && frames < 20_000 {
                world.addGateTokens(Float(rate / 60))
                for _ in 0..<SandWorld.stepsPerFrame { world.step(ax: g.ax, ay: g.ay) }
                frames += 1
            }
            let elapsed = Double(frames) / 60
            XCTAssertEqual(elapsed, seconds, accuracy: seconds * 0.04,
                           "\(total) grains should take \(seconds) s, took \(elapsed) s")
        }
    }

    func testCatchingUpMovesSandBetweenBulbsWithoutLosingAny() {
        let container = Container.hourglass(width: 70, height: 84)
        let world = SandWorld(width: 70, height: 84)
        world.apply(container)
        let neck = world.neckRows!
        world.fill(500, downward: false, rows: 0..<neck.lowerBound) { _, _ in (0xFFFF_FFFF, 0) }
        XCTAssertEqual(world.transferThroughNeck(200, downward: true), 200)
        var counts = world.bulbCounts()!
        XCTAssertEqual(counts.above, 300)
        XCTAssertEqual(counts.below, 200)
        XCTAssertEqual(world.transferThroughNeck(1000, downward: true), 300)
        counts = world.bulbCounts()!
        XCTAssertEqual(counts.above, 0)
        XCTAssertEqual(counts.below, 500)
        XCTAssertEqual(world.grainCount, 500)
    }

    func testCatchingUpOpensACraterAndBuildsACone() {
        let w = 70, h = 84
        let container = Container.hourglass(width: w, height: h)
        let world = SandWorld(width: w, height: h)
        world.apply(container)
        let neck = world.neckRows!
        world.fill(700, downward: true, rows: 0..<neck.lowerBound) { _, _ in (0xFFFF_FFFF, 0) }
        world.transferThroughNeck(250, downward: true)
        func surface(_ x: Int, from rows: [Int]) -> Int? {
            rows.first { world.kind[$0 * w + x] == SandWorld.grain }
        }
        let top = Array(0..<neck.lowerBound), bottom = Array((neck.upperBound + 1)..<h)
        // Above: the middle has sunk below the sides.
        let middle = surface(35, from: top)!, side = surface(25, from: top)!
        XCTAssertGreaterThan(middle, side + 3, "a crater over the neck")
        // Below: a heap, highest in the middle.
        let peak = surface(35, from: bottom)!, flank = surface(25, from: bottom)!
        XCTAssertLessThan(peak, flank - 3, "a cone under the neck")
        // Nothing left hanging in mid-air, above or below. (The grains over the neck rest on the
        // neck's gate.)
        for y in (top.dropLast() + bottom) where y < h - 1 {
            for x in 0..<w where world.kind[y * w + x] == SandWorld.grain {
                XCTAssertNotEqual(world.kind[(y + 1) * w + x], SandWorld.empty, "grain at \(x),\(y) floats")
            }
        }
        XCTAssertEqual(world.grainCount, 700)
    }

    func testDrainRemovesFromTheTop() {
        let (world, _) = screenWorld()
        settle(world, grains: 600)
        let removed = world.drain(100, gravityX: 0, gravityY: 1)
        XCTAssertEqual(removed, 100)
        XCTAssertEqual(world.grainCount, 500)
        XCTAssertEqual(countCells(world, SandWorld.grain), 500)
    }

    func testCarvingClearsAChannel() {
        let (world, _) = screenWorld()
        settle(world, grains: 1200)
        // Just under the surface, so there's somewhere to push the sand.
        let y: Float = 54
        world.carve(x: 30, y: y, radius: 3, fingerVX: 0, fingerVY: 0)
        for cy in Int(y) - 2...Int(y) + 2 {
            for cx in 28...32 {
                let dx = Float(cx) + 0.5 - 30, dy = Float(cy) + 0.5 - y
                if dx * dx + dy * dy < 4 {
                    XCTAssertNotEqual(world.kind[cy * world.width + cx], SandWorld.grain)
                }
            }
        }
        XCTAssertEqual(world.grainCount, 1200)
    }
}
