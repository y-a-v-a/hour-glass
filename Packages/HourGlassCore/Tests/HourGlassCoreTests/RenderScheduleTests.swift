import XCTest
@testable import HourGlassCore

final class RenderScheduleTests: XCTestCase {
    /// Runs `moves` frames through a schedule, rendering when it says so (with no streaks or glints
    /// unless asked), and returns the frames rendered and what each render stood for.
    private func run(_ schedule: inout RenderSchedule, moves: [Int], lighting: [SandRenderer.Lighting]? = nil,
                     glints: Set<Int> = []) -> [(frame: Int, stillFrames: Int)] {
        var renders: [(Int, Int)] = []
        for (n, m) in moves.enumerated() {
            let light = lighting?[n] ?? .fromAbove
            if let still = schedule.frame(moves: m, lighting: light) {
                renders.append((n, still))
                schedule.rendered(lighting: light, streaks: false, glints: glints.contains(n))
            }
        }
        return renders
    }

    func testTheFirstFrameIsRendered() {
        var schedule = RenderSchedule()
        XCTAssertEqual(run(&schedule, moves: [0]).map(\.frame), [0])
    }

    func testSandAtRestIsRenderedNowAndThenForItsGlints() {
        var schedule = RenderSchedule()
        let renders = run(&schedule, moves: Array(repeating: 0, count: 31))
        XCTAssertEqual(renders.map(\.frame), [0, 6, 12, 18, 24, 30])
        // Each render after the first stands for the six frames since the last one.
        XCTAssertEqual(renders.dropFirst().map(\.stillFrames), [6, 6, 6, 6, 6])
    }

    func testMovingSandIsRenderedAndThenOnceMoreToClearItsHighlights() {
        var schedule = RenderSchedule()
        let renders = run(&schedule, moves: [0, 0, 5, 3, 0, 0, 0])
        XCTAssertEqual(renders.map(\.frame), [0, 2, 3, 4])
    }

    func testAGlintIsClearedOnTheNextFrame() {
        var schedule = RenderSchedule()
        let renders = run(&schedule, moves: Array(repeating: 0, count: 9), glints: [6])
        XCTAssertEqual(renders.map(\.frame), [0, 6, 7])
    }

    func testTurningTheLightRenders() {
        var schedule = RenderSchedule()
        let renders = run(&schedule, moves: [0, 0, 0, 0], lighting: [.fromAbove, .fromAbove, .fromLeft, .fromLeft])
        XCTAssertEqual(renders.map(\.frame), [0, 2])
    }

    func testChangesFromOutsideRender() {
        var schedule = RenderSchedule()
        _ = run(&schedule, moves: [0, 0])
        schedule.invalidate()
        XCTAssertEqual(schedule.frame(moves: 0, lighting: .fromAbove), 2)
    }

    func testSkippedFramesStillGlintAsOftenAsEver() {
        // Every grain can glint. Rendered every frame, or every sixth frame standing in for six, the
        // sand should flash about as many glints over the same stretch of time.
        let world = SandWorld(width: 60, height: 60)
        world.apply(.screen(width: 60, height: 60, cornerRadius: 0))
        world.fill(2000) { _, _ in (SandPalette.pack(120, 100, 80), SandWorld.sparkleFlag) }
        let glint: UInt32 = 0xFF12_3456
        let renderer = SandRenderer(width: 60, height: 60)
        // Let the fill's moves age, so every grain counts as resting.
        for _ in 0..<4 { world.step(ax: 0, ay: 0) }
        func glints(renders: Int, stillFrames: Int) -> Int {
            var total = 0
            for _ in 0..<renders {
                renderer.render(world, gravityX: 0, gravityY: 1, sparkle: glint, stillFrames: stillFrames)
                for i in 0..<world.cellCount where renderer.pixels[i] == glint { total += 1 }
            }
            return total
        }
        let everyFrame = glints(renders: 600, stillFrames: 1)
        let everySixth = glints(renders: 100, stillFrames: 6)
        XCTAssertGreaterThan(everyFrame, 2000)
        XCTAssertEqual(Double(everySixth), Double(everyFrame), accuracy: Double(everyFrame) * 0.1)
    }
}
