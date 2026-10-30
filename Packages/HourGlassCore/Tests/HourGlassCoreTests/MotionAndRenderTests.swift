import XCTest
@testable import HourGlassCore

final class MotionMappingTests: XCTestCase {
    private let mapping = MotionMapping(gravityScale: 1)

    func testUprightWatchPullsSandDownTheScreen() {
        let f = mapping.forces(for: .upright)
        XCTAssertEqual(f.ax, 0, accuracy: 1e-6)
        XCTAssertEqual(f.ay, 1, accuracy: 1e-6)
    }

    func testLoweringThreeOClockSendsSandRight() {
        // 3 o'clock pointing at the floor: gravity along device +x.
        let f = mapping.forces(for: MotionSample(gravityX: 1, gravityY: 0, gravityZ: 0))
        XCTAssertGreaterThan(f.ax, 0.9)
        XCTAssertEqual(f.ay, 0, accuracy: 1e-6)
    }

    func testCrownOnTheLeftTurnsEverythingHalfAround() {
        var flipped = mapping
        flipped.flipped = true
        let f = flipped.forces(for: .upright)
        XCTAssertEqual(f.ay, -1, accuracy: 1e-6)
    }

    func testGlassFrictionHoldsSandWhenNearlyFlat() {
        // Face up, tipped by about 5°: the glass holds the sand.
        let f = mapping.forces(for: MotionSample(gravityX: 0.087, gravityY: 0, gravityZ: -0.996))
        XCTAssertEqual(f.ax, 0)
        XCTAssertEqual(f.ay, 0)
        // Tipped by 30°, it slides.
        let g = mapping.forces(for: MotionSample(gravityX: 0.5, gravityY: 0, gravityZ: -0.866))
        XCTAssertGreaterThan(g.ax, 0.3)
    }

    func testWristAccelerationAddsToGravity() {
        // Core Motion's gravity + userAcceleration is the raw reading, which is what loose sand feels.
        let still = mapping.forces(for: .upright)
        let jolted = mapping.forces(for: MotionSample(gravityX: 0, gravityY: -1, gravityZ: 0, userX: 1))
        XCTAssertGreaterThan(jolted.ax, 1.4)
        XCTAssertEqual(jolted.ay, still.ay, accuracy: 1e-6)
    }

    func testSmallTremorsAreIgnoredButTapsMakeSandHop() {
        let tremor = mapping.forces(for: MotionSample(gravityX: 0, gravityY: -1, gravityZ: 0, userX: 0.03))
        XCTAssertEqual(tremor.ax, 0, accuracy: 1e-6)
        XCTAssertEqual(tremor.agitation, 0)
        let tap = mapping.forces(for: MotionSample(gravityX: 0, gravityY: -1, gravityZ: 0, userZ: 0.8))
        XCTAssertGreaterThan(tap.agitation, 0.5)
    }
}

final class RendererTests: XCTestCase {
    func testGrainsAreOpaqueAndEmptyCellsTransparent() {
        let container = Container.screen(width: 20, height: 20, cornerRadius: 0)
        let world = SandWorld(width: 20, height: 20)
        world.apply(container)
        world.addGrain(at: 10 * 20 + 10, color: SandPalette.pack(200, 150, 100))
        world.addGrain(at: 11 * 20 + 10, color: SandPalette.pack(200, 150, 100))
        let renderer = SandRenderer(width: 20, height: 20)
        renderer.render(world, gravityX: 0, gravityY: 1, sparkle: 0xFFFF_FFFF)
        XCTAssertEqual(renderer.pixels[0], 0)
        XCTAssertEqual(renderer.pixels[5 * 20 + 5], 0)
        let top = renderer.pixels[10 * 20 + 10], below = renderer.pixels[11 * 20 + 10]
        XCTAssertEqual(top >> 24, 255)
        XCTAssertEqual(below >> 24, 255)
        // The surface grain catches the light; the one under it is in its shade.
        XCTAssertGreaterThan(top & 0xFF, below & 0xFF)
        let image = renderer.makeImage()
        XCTAssertEqual(image?.width, 20)
    }

    func testImagesKeepTheirPixelsWhileLaterFramesAreRendered() {
        let world = SandWorld(width: 30, height: 40)
        world.apply(.screen(width: 30, height: 40, cornerRadius: 0))
        world.fill(300) { _, _ in (SandPalette.pack(200, 150, 100), 0) }
        let renderer = SandRenderer(width: 30, height: 40)
        func bytes(_ image: CGImage) -> [UInt8] {
            Array(image.dataProvider!.data! as Data)
        }
        renderer.render(world, gravityX: 0, gravityY: 1, sparkle: 0)
        let first = renderer.makeImage()!
        let firstBytes = bytes(first)
        XCTAssertEqual(firstBytes.count, 30 * 40 * 4)
        // Images go and come while the first is still held: its memory mustn't be handed out.
        for n in 0..<6 {
            world.drain(40, gravityX: 0, gravityY: 1)
            renderer.render(world, gravityX: n % 2 == 0 ? 1 : 0, gravityY: 1, sparkle: 0)
            let later = renderer.makeImage()!
            XCTAssertNotEqual(bytes(later), firstBytes)
            XCTAssertEqual(bytes(later), (0..<(30 * 40 * 4)).map { k in
                UInt8(truncatingIfNeeded: renderer.pixels[k / 4] >> (8 * UInt32(k % 4)))
            })
        }
        XCTAssertEqual(bytes(first), firstBytes)
    }

    func testPalettesMakeVariedGrains() {
        var rng = FastRandom(seed: 7)
        for palette in SandPalette.all {
            let colors = Set((0..<200).map { _ in palette.makeGrain(&rng).color })
            XCTAssertGreaterThan(colors.count, 50, palette.name)
            XCTAssertTrue(colors.allSatisfy { $0 >> 24 == 255 }, palette.name)
        }
    }
}
