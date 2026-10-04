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
    private var rng = FastRandom(seed: 0xD15C_0BA11)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = .allocate(capacity: width * height)
        pixels.update(repeating: 0, count: width * height)
        depthShade = (0..<24).map { depth in
            let d = Float(max(depth, 1) - 1)
            return Int32((0.8 + 0.36 * expf(-d / 3.2)) * 256)
        }
    }

    deinit {
        pixels.deallocate()
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
        let frame = world.frame
        let level = Int32(brightness * 256)

        let recent = UInt8(max(1, min(recentSteps, 200)))
        @inline(__always)
        func shade(_ i: Int, _ depth: Int) -> UInt32 {
            // Step numbers wrap within 1...255.
            let age = frame >= moved[i] ? frame - moved[i] : frame &+ (255 &- moved[i])
            let movedNow = age < recent
            if flags[i] & SandWorld.sparkleFlag != 0 {
                let chance: Float = movedNow ? 0.3 : 0.0025
                if rng.unit() < chance { return scale(sparkle, level) }
            }
            var f = depthShade[min(depth, depthShade.count - 1)]
            if movedNow { f += 16 }
            return scale(color[i], (f * level) >> 8)
        }

        // Walk each line from the side gravity comes from, counting grains since the last gap.
        if abs(gravityY) >= abs(gravityX) {
            let fromTop = gravityY >= 0
            for x in 0..<w {
                var depth = 0
                for r in 0..<h {
                    let i = (fromTop ? r : h - 1 - r) * w + x
                    if kind[i] == SandWorld.grain {
                        depth += 1
                        pixels[i] = shade(i, depth)
                    } else {
                        depth = 0
                        pixels[i] = 0
                    }
                }
            }
        } else {
            let fromLeft = gravityX >= 0
            for y in 0..<h {
                var depth = 0
                let row = y * w
                for c in 0..<w {
                    let i = row + (fromLeft ? c : w - 1 - c)
                    if kind[i] == SandWorld.grain {
                        depth += 1
                        pixels[i] = shade(i, depth)
                    } else {
                        depth = 0
                        pixels[i] = 0
                    }
                }
            }
        }
        drawTrails(world, level: level)
    }

    /// Smears fast grains into short streaks behind them, as the eye would, so a trickle of sand
    /// reads as a stream rather than a dotted line.
    private func drawTrails(_ world: SandWorld, level: Int32) {
        let w = width, h = height
        let kind = world.kind, color = world.color
        let vx = world.velocityX, vy = world.velocityY
        let minSpeed: Float = 0.9
        for i in 0..<(w * h) where kind[i] == SandWorld.grain {
            let sx = vx[i], sy = vy[i]
            let speed2 = sx * sx + sy * sy
            guard speed2 > minSpeed * minSpeed else { continue }
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
