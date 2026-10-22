import CoreGraphics
import Foundation
import HourGlassCore
import ImageIO
import UniformTypeIdentifiers

// Renders scripted scenes with the real simulation and renderer, to look at the sand without a
// watch, and benchmarks the simulation.
//
//   swift run -c release sandpreview [scene] [--out dir] [--palette id] [--grain px]
//   scenes: pour, tilt, shake, hourglass, carve, palettes, bench, all (default)

struct Options {
    var scene = "all"
    var out = URL(fileURLWithPath: "preview", isDirectory: true)
    var palette = SandPalette.sahara
    /// Pixels per grain on a 46 mm Series 11 (416 × 496 px).
    var grain = 3
}

var options = Options()
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--out": options.out = URL(fileURLWithPath: args.popFirst() ?? "preview", isDirectory: true)
    case "--palette": options.palette = SandPalette.named(args.popFirst() ?? "")
    case "--grain": options.grain = Int(args.popFirst() ?? "") ?? 3
    default: options.scene = arg
    }
}
try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)

let screenWidth = 416, screenHeight = 496

// MARK: - Scene plumbing

final class Scene {
    let world: SandWorld
    let renderer: SandRenderer
    let palette: SandPalette
    let container: Container
    let scale: Int
    var gravity: (Float, Float) = (0, 1)
    var frames: [CGImage] = []
    var poured = 0
    var clock = 0
    /// Where the pour stream enters at a given step; `nil` scatters it.
    var pourPosition: (Int) -> Float? = { step in 0.5 + 0.42 * sinf(Float(step) * 0.045) }

    init(shape: Container.Shape, palette: SandPalette, grain: Int) {
        scale = grain
        let w = screenWidth / grain, h = screenHeight / grain
        container = shape == .screen
            ? .screen(width: w, height: h, cornerRadius: Float(w) * 0.21)
            : .hourglass(width: w, height: h)
        world = SandWorld(width: w, height: h)
        world.apply(container)
        world.parameters = .tuned(forHeight: h)
        renderer = SandRenderer(width: w, height: h)
        self.palette = palette
    }

    var mapping: MotionMapping { .tuned(forHeight: world.height) }

    /// Steps with the watch tilted so in-plane gravity points `degrees` clockwise from straight
    /// down the screen, at `strength` g.
    func run(_ steps: Int, degrees: Float = 0, strength: Float = 0.8, shakeX: Float = 0,
             shakeY: Float = 0, pour: Int = 0, record every: Int = 0) {
        let radians = degrees * .pi / 180
        // Screen-down is device −y; rotating clockwise on screen moves it towards device −x.
        let sample = MotionSample(gravityX: -sinf(radians) * strength,
                                  gravityY: -cosf(radians) * strength,
                                  gravityZ: -(1 - strength * strength).squareRoot(),
                                  userX: shakeX, userY: shakeY)
        let f = mapping.forces(for: sample)
        gravity = (f.ax, f.ay)
        for s in 0..<steps {
            if pour > 0 {
                let palette = self.palette
                let band = poured / max(1, world.cellCount / 40)
                // Three streams sweeping back and forth out of step with each other.
                for stream in 0..<3 {
                    let phase = Float(stream) * 2.1
                    let position = pourPosition(clock).map { _ in
                        0.5 + 0.45 * sinf(Float(clock) * 0.03 * (1 + Float(stream) * 0.37) + phase)
                    }
                    poured += world.pour(pour / 3, gravityX: f.ax, gravityY: f.ay, at: position,
                                         spread: Float(world.width) * 0.05) { rng in
                        palette.makeGrain(&rng, band: band)
                    }
                }
            }
            clock += 1
            if pour == 0 { clock += 1 }
            for _ in 0..<SandWorld.stepsPerFrame {
                world.step(ax: f.ax, ay: f.ay, agitation: f.agitation, drag: f.drag)
            }
            if every > 0 && s % every == 0 { frames.append(snapshot()) }
        }
    }

    func snapshot() -> CGImage {
        renderer.render(world, gravityX: gravity.0, gravityY: gravity.1, sparkle: palette.packedSparkle)
        return composite()
    }

    func composite() -> CGImage {
        let w = world.width * scale, h = world.height * scale
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let top = color(palette.backgroundTop), bottom = color(palette.backgroundBottom)
        let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: .zero, options: [])
        // Flip to the simulation's y-down cell coordinates.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        if let glass = container.glass {
            ctx.addPath(glass.outline(inset: -0.6))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.05))
            ctx.fillPath()
        }
        if let image = renderer.makeImage() {
            ctx.interpolationQuality = .none
            ctx.saveGState()
            // CGContext draws images upright in its own (flipped back) coordinates.
            ctx.translateBy(x: 0, y: CGFloat(world.height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: world.width, height: world.height))
            ctx.restoreGState()
        }
        if let glass = container.glass {
            ctx.addPath(glass.outline(inset: -0.6))
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.45))
            ctx.setLineWidth(0.5)
            ctx.strokePath()
        }
        return ctx.makeImage()!
    }

    func color(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    func save(_ name: String) {
        writePNG(snapshot(), name)
    }

    /// Writes `count` evenly spaced recorded frames as a sheet, to judge motion at a glance.
    func saveFilmstrip(_ name: String, count: Int = 8, columns: Int = 8) {
        guard frames.count > 1 else { return }
        let saved = stills
        stills = []
        for k in 0..<count {
            let index = k * (frames.count - 1) / max(1, count - 1)
            stills.append(("\(index)", frames[index]))
        }
        writeSheet(name, columns: columns)
        stills = saved
    }

    func saveGIF(_ name: String, delay: Double = 1.0 / 30) {
        let url = options.out.appendingPathComponent("\(name).gif")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                         frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for frame in frames { CGImageDestinationAddImage(dest, frame, props) }
        CGImageDestinationFinalize(dest)
        print("wrote \(url.path) (\(frames.count) frames)")
        frames.removeAll()
    }
}

/// Every still written so far, for the contact sheet.
var stills: [(String, CGImage)] = []

/// Writes the stills side by side, wrapping after `columns`, with a gap between them.
func writeSheet(_ name: String, columns: Int = 4) {
    guard let first = stills.first?.1 else { return }
    let w = first.width, h = first.height, gap = 8
    let cols = min(columns, stills.count), rows = (stills.count + cols - 1) / cols
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: cols * w + (cols - 1) * gap, height: rows * h + (rows - 1) * gap,
                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    for (n, (_, image)) in stills.enumerated() {
        let col = n % cols, row = n / cols
        ctx.draw(image, in: CGRect(x: col * (w + gap), y: ctx.height - (row + 1) * h - row * gap,
                                   width: image.width, height: image.height))
    }
    let names = stills.map(\.0).joined(separator: ", ")
    stills.removeAll()
    writePNG(ctx.makeImage()!, name, keep: false)
    print("  sheet order: \(names)")
}

func writePNG(_ image: CGImage, _ name: String, keep: Bool = true) {
    if keep { stills.append((name, image)) }
    let url = options.out.appendingPathComponent("\(name).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path)")
}

func fillFraction(_ scene: Scene, _ fraction: Double) -> Int {
    Int(Double(scene.container.interiorCount) * fraction)
}

// MARK: - Scenes

func pourScene() {
    let scene = Scene(shape: .screen, palette: options.palette, grain: options.grain)
    let target = fillFraction(scene, 0.38)
    let perStep = target / 150
    scene.run(90, pour: perStep, record: 2)
    scene.save("pour-1-falling")
    scene.run(60, pour: perStep, record: 2)
    scene.run(120, record: 2)
    scene.save("pour-2-settled")
    scene.saveGIF("pour")
    print("grains: \(scene.world.grainCount) of target \(target)")
}

func settledScene(palette: SandPalette = options.palette) -> Scene {
    let scene = Scene(shape: .screen, palette: palette, grain: options.grain)
    let target = fillFraction(scene, 0.38)
    scene.run(150, pour: target / 150)
    scene.run(150)
    return scene
}

func tiltScene() {
    let scene = settledScene()
    // A quick look at how promptly a steep tilt gets going: every 3rd step for the first 48.
    let flat = Scene(shape: .screen, palette: options.palette, grain: options.grain)
    let palette = flat.palette
    flat.world.fill(fillFraction(flat, 0.38)) { rng, _ in palette.makeGrain(&rng) }
    for steps in [0, 20, 40, 80, 160, 320, 480, 900] {
        flat.run(steps - flat.clock, degrees: 60, strength: 0.9)
        flat.frames.append(flat.snapshot())
    }
    flat.saveFilmstrip("tilt-onset")
    scene.run(90, degrees: 25, record: 2)
    scene.save("tilt-1-25deg")
    scene.run(120, degrees: 50, record: 2)
    scene.save("tilt-2-50deg")
    scene.run(150, degrees: 180, strength: 0.9, record: 2)
    scene.save("tilt-3-upside-down")
    scene.run(150, degrees: -90, strength: 0.9, record: 2)
    scene.save("tilt-4-left")
    scene.saveGIF("tilt")
}

func shakeScene() {
    let scene = settledScene()
    scene.frames.append(scene.snapshot())
    // A sharp flick to the right: the watch accelerates right (sand pushed left), then brakes.
    scene.run(5, strength: 0.6, shakeX: -1.8, record: 1)
    scene.save("shake-1-flick")
    scene.run(5, strength: 0.6, shakeX: 2.2, record: 1)
    scene.run(4, strength: 0.6, record: 1)
    scene.save("shake-2-splash")
    scene.run(60, strength: 0.6, record: 1)
    scene.save("shake-3-after")
    // Then a jolt upward: sand flies to the top and rains back down.
    scene.run(6, strength: 0.6, shakeY: 2.5, record: 1)
    scene.run(6, strength: 0.6, shakeY: -2.5, record: 1)
    scene.run(90, strength: 0.6, record: 1)
    scene.save("shake-4-rain")
    scene.saveGIF("shake")
}

func carveScene() {
    let scene = settledScene()
    // Watch flat on a table: little in-plane gravity, so sand holds whatever shape it's pushed into.
    let w = Float(scene.world.width), h = Float(scene.world.height)
    var x: Float = w * 0.15
    let y: Float = h * 0.8
    for _ in 0..<80 {
        scene.world.carve(x: x, y: y + sinf(x / 9) * 8, radius: 3.5, fingerVX: 1, fingerVY: 0)
        scene.run(1, strength: 0.05)
        x += w * 0.7 / 80
        scene.frames.append(scene.snapshot())
    }
    scene.save("carve-1-drawn")
    scene.world.burst(x: w * 0.5, y: h * 0.75, radius: 22, strength: 6)
    scene.run(40, strength: 0.7, record: 1)
    scene.save("carve-2-burst")
    scene.saveGIF("carve")
}

func hourglassScene() {
    let scene = Scene(shape: .hourglass, palette: options.palette, grain: options.grain)
    let capacity = scene.container.bulbCapacity()
    let palette = scene.palette
    let rows = scene.world.neckRows!
    let bandRows = 6
    scene.world.fill(Int(Double(capacity) * 0.82), rows: (rows.upperBound + 1)..<scene.world.height) { rng, row in
        palette.makeGrain(&rng, band: row / bandRows)
    }
    scene.run(30)
    scene.save("hourglass-1-resting")
    scene.world.rotateHalfTurn()
    scene.world.metersFlow = true
    // The first moments after turning it over, frame by frame.
    let collapse = Scene(shape: .hourglass, palette: options.palette, grain: options.grain)
    collapse.world.fill(Int(Double(capacity) * 0.82), rows: (rows.upperBound + 1)..<collapse.world.height) { rng, row in
        palette.makeGrain(&rng, band: row / bandRows)
    }
    collapse.world.rotateHalfTurn()
    collapse.world.metersFlow = true
    for frame in 0..<800 {
        collapse.world.addGateTokens(2)
        collapse.run(1)
        if frame % 114 == 0 { collapse.frames.append(collapse.snapshot()) }
    }
    collapse.saveFilmstrip("hourglass-collapse", count: 8)
    collapse.frames.removeAll()
    // 2 grains per step: fast enough to watch.
    for s in 0..<600 {
        scene.world.addGateTokens(2)
        scene.run(1)
        if s % 4 == 0 { scene.frames.append(scene.snapshot()) }
        if s == 300 { scene.save("hourglass-2-flowing") }
    }
    scene.save("hourglass-3-later")
    scene.saveGIF("hourglass")
    let counts = scene.world.bulbCounts()!
    print("hourglass: above \(counts.above), below \(counts.below), capacity \(capacity)")
}

/// The app icon: an hourglass part way through, on a warm backdrop, 1024 × 1024.
func iconScene() {
    let size = 1024, cells = 256
    let container = Container.hourglass(width: cells, height: cells)
    let world = SandWorld(width: cells, height: cells, seed: 7)
    world.apply(container)
    world.parameters = .tuned(forHeight: cells)
    let mapping = MotionMapping.tuned(forHeight: cells)
    let palette = SandPalette.sahara
    let neck = world.neckRows!
    let total = world.fill(Int(Double(container.bulbCapacity()) * 0.8), rows: (neck.upperBound + 1)..<cells) { rng, _ in
        palette.makeGrain(&rng)
    }
    world.rotateHalfTurn()
    world.metersFlow = true
    let f = mapping.forces(for: .upright)
    // Run until about 45% has gone through, then a few frames more so the stream is mid-air.
    var frames = 0
    while (world.bulbCounts()?.below ?? 0) < total * 45 / 100 && frames < 20_000 {
        // About the rate of a real timer, so the top drains the way it would.
        world.addGateTokens(1.2)
        for _ in 0..<SandWorld.stepsPerFrame { world.step(ax: f.ax, ay: f.ay) }
        frames += 1
    }
    let renderer = SandRenderer(width: cells, height: cells)
    renderer.render(world, gravityX: 0, gravityY: 1, sparkle: palette.packedSparkle)

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Opaque: app icons may not have an alpha channel.
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    let backdrop = CGGradient(colorsSpace: space, colors: [rgb(0x4A3020), rgb(0x1A100A), rgb(0x080504)] as CFArray,
                              locations: [0, 0.6, 1])!
    ctx.drawRadialGradient(backdrop, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 724, options: [.drawsAfterEndLocation])

    // Watch icons are masked to a circle: keep the frame's corners well inside it.
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: 0.84, y: 0.84)
    ctx.translateBy(x: -512, y: -512)
    // Cell coordinates, y down.
    let k = CGFloat(size) / CGFloat(cells)
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: k, y: -k)
    let glass = container.glass!
    let outline = glass.outline(inset: -0.6)
    ctx.addPath(outline)
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.06))
    ctx.fillPath()
    if let image = renderer.makeImage() {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: CGFloat(cells))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: cells, height: cells))
        ctx.restoreGState()
    }
    ctx.addPath(outline)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.5))
    ctx.setLineWidth(1.4)
    ctx.strokePath()
    // A highlight down the left of each bulb.
    let left = glass.profile(side: -1, inset: 4)
    let span = glass.bottom - glass.top
    for (from, to) in [(0.06, 0.36), (0.64, 0.94)] {
        let segment = left.filter { Float($0.y) >= glass.top + span * Float(from) && Float($0.y) <= glass.top + span * Float(to) }
        ctx.addLines(between: segment)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(2.4)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    // Wooden posts and caps.
    let cx = CGFloat(glass.centerX), half = CGFloat(glass.bulbHalfWidth) + 14
    let capHeight: CGFloat = 13, postWidth: CGFloat = 7
    let wood = CGGradient(colorsSpace: space, colors: [rgb(0x9E6B40), rgb(0x70472A), rgb(0x402614)] as CFArray,
                          locations: [0, 0.5, 1])!
    let woodAcross = CGGradient(colorsSpace: space, colors: [rgb(0x402614), rgb(0x9E6B40), rgb(0x70472A), rgb(0x402614)] as CFArray,
                                locations: [0, 0.35, 0.65, 1])!
    for side: CGFloat in [-1, 1] {
        let x = cx + side * (CGFloat(glass.bulbHalfWidth) + 7 + postWidth / 2)
        let rect = CGRect(x: x - postWidth / 2, y: CGFloat(glass.top) - capHeight / 2, width: postWidth,
                          height: CGFloat(glass.bottom - glass.top) + capHeight)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: postWidth / 2, cornerHeight: postWidth / 2, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(woodAcross, start: CGPoint(x: rect.minX, y: 0), end: CGPoint(x: rect.maxX, y: 0), options: [])
        ctx.restoreGState()
    }
    for y in [CGFloat(glass.top) - capHeight, CGFloat(glass.bottom)] {
        let rect = CGRect(x: cx - half, y: y, width: half * 2, height: capHeight)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(wood, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        ctx.restoreGState()
        ctx.move(to: CGPoint(x: rect.minX + 4, y: rect.minY + 1.2))
        ctx.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.minY + 1.2))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.3))
        ctx.setLineWidth(1.2)
        ctx.strokePath()
    }
    let icon = ctx.makeImage()!
    // Watch icons are square artwork masked to a circle; no alpha allowed.
    writePNG(icon, "AppIcon")
    print("icon after \(frames) frames")
}

func paletteScene() {
    for palette in SandPalette.all {
        let scene = settledScene(palette: palette)
        scene.run(60, degrees: 20)
        scene.save("palette-\(palette.id)")
    }
}

/// Times the simulation and the renderer in the situations the app spends its time in, at each
/// grain size. Every case is scripted from fixed seeds, so runs are comparable from build to build.
func bench() {
    struct Case {
        var name: String
        var frames: Int
        /// Builds the scene to be timed (untimed).
        var setup: (Int) -> Scene
        /// Simulates frame `n`.
        var frame: (Scene, Int) -> Void
    }
    func settled(_ grain: Int) -> Scene {
        let scene = Scene(shape: .screen, palette: .sahara, grain: grain)
        let target = fillFraction(scene, 0.4)
        scene.run(150, pour: target / 150)
        scene.run(100)
        return scene
    }
    let cases = [
        // Sand sloshing round as the wrist turns: lots of grains in flight.
        Case(name: "slosh", frames: 600, setup: settled) { scene, n in
            scene.run(1, degrees: Float(n) * 0.9, strength: 0.9)
        },
        // Looking at the watch: the wrist sways a few degrees, so the sand stays awake, but
        // nearly all of it is resting.
        Case(name: "held", frames: 600, setup: settled) { scene, n in
            scene.run(1, degrees: 4 * sinf(Float(n) * 0.05), strength: 0.8)
        },
        // The opening pour.
        Case(name: "pour", frames: 150, setup: { Scene(shape: .screen, palette: .sahara, grain: $0) }) { scene, _ in
            scene.run(1, pour: fillFraction(scene, 0.4) / 150)
        },
        // A one-minute hourglass running, turned over a moment before.
        Case(name: "hourglass", frames: 600, setup: { grain in
            let scene = Scene(shape: .hourglass, palette: .sahara, grain: grain)
            let rows = scene.world.neckRows!
            scene.world.fill(Int(Double(scene.container.bulbCapacity()) * 0.82),
                             rows: (rows.upperBound + 1)..<scene.world.height) { rng, _ in
                scene.palette.makeGrain(&rng)
            }
            scene.run(30)
            scene.world.rotateHalfTurn()
            scene.world.metersFlow = true
            scene.run(60)
            return scene
        }) { scene, _ in
            // All the sand through in 60 s.
            scene.world.addGateTokens(Float(scene.world.grainCount) / 60 / 60)
            scene.run(1)
        },
    ]
    let repeats = 5
    func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }
    func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    print("ms per frame (\(SandWorld.stepsPerFrame) steps), median of \(repeats) runs")
    for grain in [2, 3, 4] {
        for c in cases {
            var simulate: [Double] = [], render: [Double] = []
            var grains = 0, size = ""
            for _ in 0..<repeats {
                let scene = c.setup(grain)
                var sim = 0.0, draw = 0.0
                for n in 0..<c.frames {
                    sim += milliseconds { c.frame(scene, n) }
                    draw += milliseconds {
                        scene.renderer.render(scene.world, gravityX: scene.gravity.0, gravityY: scene.gravity.1,
                                              sparkle: scene.palette.packedSparkle)
                        _ = scene.renderer.makeImage()
                    }
                }
                simulate.append(sim / Double(c.frames))
                render.append(draw / Double(c.frames))
                grains = scene.world.grainCount
                size = "\(scene.world.width)x\(scene.world.height)"
            }
            let name = c.name.padding(toLength: 9, withPad: " ", startingAt: 0)
            print(String(format: "grain %dpx %@ %@, %5d grains: simulate %.3f  render %.3f",
                         grain, name, size, grains, median(simulate), median(render)))
        }
    }
}

let scenes: [String: () -> Void] = [
    "pour": pourScene, "tilt": tiltScene, "shake": shakeScene, "carve": carveScene,
    "hourglass": hourglassScene, "palettes": paletteScene, "icon": iconScene,
]
if options.scene == "bench" {
    bench()
} else {
    for name in options.scene == "all" ? scenes.keys.sorted().filter { $0 != "icon" } : [options.scene] {
        guard let scene = scenes[name] else { print("unknown scene \(name)"); exit(1) }
        scene()
        if name == "icon" { stills.removeAll() } else { writeSheet("\(name)-sheet", columns: name == "palettes" ? 5 : 4) }
    }
}
