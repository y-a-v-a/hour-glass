import CoreGraphics
import Foundation

/// Turns a `SandWorld` into an image with one pixel per cell, to be scaled up without smoothing.
///
/// The light comes from "above", i.e. against gravity: the top grain of each heap is brightest and
/// sand gets darker the deeper it lies, which gives piles their volume. Moving sand catches a
/// little more light, and glinting grains flash as they tumble.
public final class SandRenderer {
    public let width: Int
    public let height: Int
    /// Premultiplied RGBA, one per cell. Empty cells and walls are transparent.
    public let pixels: UnsafeMutablePointer<UInt32>

    /// Brightness by depth below the surface (256 = unchanged).
    private let depthShade: [Int32]
    /// The same with the overall level folded in, for still sand and then for moving sand.
    private var shadeFactors = [Int32](repeating: 0, count: 2 * depthLevels)
    private var factorsLevel: Int32 = -1
    private static let depthLevels = 24
    /// How deep each column's sand runs so far, while walking the rows.
    private let columnDepth: UnsafeMutablePointer<UInt8>
    /// Grains fast enough to leave a streak, in the order they were shaded.
    private let fast: UnsafeMutablePointer<Int32>
    /// Counts renders, so glints change from frame to frame.
    private var tick: UInt64 = 0xD15C_0BA11
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = .allocate(capacity: width * height)
        pixels.update(repeating: 0, count: width * height)
        columnDepth = .allocate(capacity: width + 8)
        columnDepth.initialize(repeating: 0, count: width + 8)
        fast = .allocate(capacity: width * height)
        depthShade = (0..<Self.depthLevels).map { depth in
            let d = Float(max(depth, 1) - 1)
            return Int32((0.8 + 0.36 * expf(-d / 3.2)) * 256)
        }
    }

    deinit {
        pixels.deallocate()
        columnDepth.deallocate()
        fast.deallocate()
    }

    /// Shades every grain.
    ///
    /// - Parameters:
    ///   - gravityX: The direction sand is falling in, along x; only its sign and its size relative
    ///     to `gravityY` matter.
    ///   - sparkle: Packed colour of a glint.
    ///   - brightness: Overall level, 1 for normal; lower for the always-on display.
    ///   - recentSteps: Grains that moved within this many steps count as moving.
    public func render(_ world: SandWorld, gravityX: Float, gravityY: Float, sparkle: UInt32,
                       brightness: Float = 1, recentSteps: Int = SandWorld.stepsPerFrame) {
        precondition(world.width == width && world.height == height)
        let w = width, h = height
        let kind = world.kind, color = world.color, flags = world.grainFlags, moved = world.moved
        let vx = world.velocityX, vy = world.velocityY
        let frame = world.frame
        let level = Int32(brightness * 256)
        if level != factorsLevel {
            factorsLevel = level
            for depth in 0..<Self.depthLevels {
                shadeFactors[depth] = (depthShade[depth] * level) >> 8
                shadeFactors[Self.depthLevels + depth] = ((depthShade[depth] + 16) * level) >> 8
            }
        }
        tick &+= 1
        let tick = tick
        let glint = scale(sparkle, level)
        let recent = UInt8(max(1, min(recentSteps, 200)))
        let minSpeed: Float = 0.9
        let fast = fast
        var fastCount = 0

        // Walk the grid from the side gravity comes from, counting grains since the last gap:
        // down each column when gravity is mostly vertical (all columns at once, a row at a time,
        // so memory is read in order), or along each row when it's sideways. Either way that's one
        // sweep through the cells, forwards or backwards.
        let vertical = abs(gravityY) >= abs(gravityX)
        let backwards = vertical ? gravityY < 0 : gravityX < 0
        let columnDepth = columnDepth
        columnDepth.update(repeating: 0, count: w)

        shadeFactors.withUnsafeBufferPointer { factors in
            @inline(__always)
            func shade(_ i: Int, _ depth: Int) -> UInt32 {
                // Step numbers wrap within 1...255.
                let age = frame >= moved[i] ? frame - moved[i] : frame &+ (255 &- moved[i])
                let movedNow = age < recent
                if flags[i] & SandWorld.sparkleFlag != 0 {
                    let chance: Float = movedNow ? 0.3 : 0.0025
                    if Self.random(i, tick) < chance { return glint }
                }
                let f = factors[(movedNow ? Self.depthLevels : 0) + min(depth, Self.depthLevels - 1)]
                return scale(color[i], f)
            }

            /// Shades cell `i` of column `x` and returns its new depth.
            @inline(__always)
            func cell(_ i: Int, _ depth: Int) -> Int {
                guard kind[i] == SandWorld.grain else {
                    pixels[i] = 0
                    return 0
                }
                // Depth only matters down to the last shade, so it's kept small enough for a byte.
                let depth = min(depth + 1, Self.depthLevels)
                pixels[i] = shade(i, depth)
                let sx = vx[i], sy = vy[i]
                if sx * sx + sy * sy > minSpeed * minSpeed {
                    fast[fastCount] = Int32(truncatingIfNeeded: i)
                    fastCount += 1
                }
                return depth
            }

            let raw = UnsafeRawPointer(kind)
            for r in 0..<h {
                let y = backwards ? h - 1 - r : r
                let row = y * w
                var depth = 0
                var c = 0
                while c < w {
                    let x = backwards ? w - 1 - c : c
                    // Eight cells with no sand in them: clear them in one go.
                    if c + 8 <= w {
                        let first = backwards ? x - 7 : x
                        let cells = raw.loadUnaligned(fromByteOffset: row + first, as: UInt64.self)
                        if cells & 0x0101_0101_0101_0101 == 0 {
                            (pixels + row + first).update(repeating: 0, count: 8)
                            if vertical {
                                UnsafeMutableRawPointer(columnDepth + first).storeBytes(of: 0, as: UInt64.self)
                            }
                            depth = 0
                            c += 8
                            continue
                        }
                    }
                    if vertical {
                        columnDepth[x] = UInt8(truncatingIfNeeded: cell(row + x, Int(columnDepth[x])))
                    } else {
                        depth = cell(row + x, depth)
                    }
                    c += 1
                }
            }
        }
        drawTrails(world, fast: fast, count: fastCount, backwards: backwards, level: level)
    }

    /// Smears fast grains into short streaks behind them, as the eye would, so a trickle of sand
    /// reads as a stream rather than a dotted line. Grains are taken in grid order, so where
    /// streaks overlap evenly the same one wins whichever way the grid was walked.
    private func drawTrails(_ world: SandWorld, fast: UnsafeMutablePointer<Int32>, count: Int,
                            backwards: Bool, level: Int32) {
        let w = width, h = height
        let kind = world.kind, color = world.color
        let vx = world.velocityX, vy = world.velocityY
        for n in 0..<count {
            let i = Int(fast[backwards ? count - 1 - n : n])
            let sx = vx[i], sy = vy[i]
            let speed2 = sx * sx + sy * sy
            let speed = speed2.squareRoot()
            // About how far the grain travelled this frame, so a thin trickle joins up.
            let length = min(Int(speed * Float(SandWorld.stepsPerFrame) * 1.4), 18)
            guard length > 0 else { continue }
            let ux = -sx / speed, uy = -sy / speed
            let x0 = Float(i % w) + 0.5, y0 = Float(i / w) + 0.5
            let base = color[i]
            for k in 1...length {
                let x = Int(x0 + ux * Float(k)), y = Int(y0 + uy * Float(k))
                guard x >= 0, y >= 0, x < w, y < h else { break }
                let t = y * w + x
                if kind[t] == SandWorld.wall { break }
                guard kind[t] == SandWorld.empty else { continue }
                // Fade out along the streak; keep the stronger of overlapping streaks.
                let alpha = Int32(150 * (length + 1 - k) / (length + 1)) * level >> 8
                if Int32(pixels[t] >> 24) < alpha { pixels[t] = premultiplied(base, alpha) }
            }
        }
    }

    /// A random value in `0..<1` for cell `i` in render `tick`: a hash rather than a running
    /// generator, so it doesn't matter in which order cells are shaded.
    @inline(__always)
    private static func random(_ i: Int, _ tick: UInt64) -> Float {
        // SplitMix64's finaliser.
        var z = UInt64(truncatingIfNeeded: i) &+ tick &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) * (1.0 / 16_777_216.0)
    }

    @inline(__always)
    private func premultiplied(_ c: UInt32, _ alpha: Int32) -> UInt32 {
        let r = (Int32(c & 0xFF) * alpha) / 255
        let g = (Int32(c >> 8 & 0xFF) * alpha) / 255
        let b = (Int32(c >> 16 & 0xFF) * alpha) / 255
        return UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(alpha) << 24
    }

    @inline(__always)
    private func scale(_ c: UInt32, _ f: Int32) -> UInt32 {
        let r = min(255, (Int32(c & 0xFF) * f) >> 8)
        let g = min(255, (Int32(c >> 8 & 0xFF) * f) >> 8)
        let b = min(255, (Int32(c >> 16 & 0xFF) * f) >> 8)
        return UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000
    }

    /// A snapshot of the pixels. It owns a copy, so the next render can't tear it.
    public func makeImage() -> CGImage? {
        let data = Data(bytes: pixels, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
