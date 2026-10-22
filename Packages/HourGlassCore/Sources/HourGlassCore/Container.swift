import CoreGraphics
import Foundation

/// The vessel the sand lives in, rasterised to the simulation grid.
///
/// Everything outside the vessel is wall, including a one-cell border, so the simulation never has
/// to bounds-check a neighbour.
public struct Container {
    public enum Shape: String, CaseIterable, Sendable {
        /// The whole display, with corners rounded like the watch's screen.
        case screen
        /// A glass hourglass in the middle of the display, with a metered neck.
        case hourglass
    }

    public let shape: Shape
    public let width: Int
    public let height: Int
    /// `true` for cells the sand can't enter.
    public let walls: [Bool]
    /// `true` for the hourglass neck, where the flow is metered (all `false` for the screen).
    public let neck: [Bool]
    /// The glass outline, for the hourglass only.
    public let glass: HourglassGeometry?

    public var interiorCount: Int { walls.lazy.filter { !$0 }.count }

    /// The whole grid, with each corner cut to `cornerRadius` cells.
    public static func screen(width: Int, height: Int, cornerRadius: Float) -> Container {
        var walls = [Bool](repeating: true, count: width * height)
        // The open area spans cells 1...(n-2), i.e. the coordinates 1..<(n-1).
        let minX: Float = 1, maxX = Float(width - 1)
        let minY: Float = 1, maxY = Float(height - 1)
        let r = max(0, min(cornerRadius, (maxX - minX) / 2, (maxY - minY) / 2))
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                // Distance from the inner rectangle the corner arcs are centred on.
                let dx = max(minX + r - px, 0, px - (maxX - r))
                let dy = max(minY + r - py, 0, py - (maxY - r))
                walls[y * width + x] = dx * dx + dy * dy > r * r
            }
        }
        return Container(shape: .screen, width: width, height: height, walls: walls,
                         neck: [Bool](repeating: false, count: width * height), glass: nil)
    }

    /// An hourglass centred on the grid. The shape is symmetric under a half turn, so flipping the
    /// hourglass only has to rotate the sand.
    ///
    /// - Parameters:
    ///   - capRoom: Cells to leave above and below the glass for its caps.
    ///   - maxHalfWidth: The widest the bulbs may be, in cells from the middle.
    public static func hourglass(width: Int, height: Int, capRoom: Float? = nil,
                                 maxHalfWidth: Float? = nil) -> Container {
        let geometry = HourglassGeometry(width: width, height: height,
                                         capRoom: capRoom ?? Float(height) * 0.13,
                                         maxHalfWidth: maxHalfWidth ?? Float(width) * 0.25)
        var walls = [Bool](repeating: true, count: width * height)
        var neck = [Bool](repeating: false, count: width * height)
        for y in 1..<(height - 1) {
            let py = Float(y) + 0.5
            guard let half = geometry.halfWidth(atY: py) else { continue }
            let isNeckRow = abs(py - geometry.centerY) <= geometry.neckLength
            for x in 1..<(width - 1) where abs(Float(x) + 0.5 - geometry.centerX) <= half {
                walls[y * width + x] = false
                neck[y * width + x] = isNeckRow
            }
        }
        return Container(shape: .hourglass, width: width, height: height, walls: walls, neck: neck,
                         glass: geometry)
    }

    /// Open cells strictly on one side of the neck: the capacity of one bulb.
    public func bulbCapacity() -> Int {
        guard let glass else { return interiorCount }
        let neckTop = Int((glass.centerY - glass.neckLength).rounded(.down))
        var count = 0
        for y in 0..<neckTop {
            for x in 0..<width where !walls[y * width + x] { count += 1 }
        }
        return count
    }
}

/// The silhouette of the hourglass, in cell units with y pointing down.
public struct HourglassGeometry: Sendable, Equatable {
    public let centerX: Float
    /// The middle of the neck.
    public let centerY: Float
    /// From the neck to the flat end of either bulb.
    public let halfHeight: Float
    public let bulbHalfWidth: Float
    public let neckHalfWidth: Float
    /// Half the height of the metered part of the neck.
    public let neckLength: Float

    /// Where the bulbs are widest, as a fraction of `halfHeight` from the neck.
    private let shoulder: Float = 0.6

    init(width: Int, height: Int, capRoom: Float, maxHalfWidth: Float) {
        centerX = Float(width) / 2
        centerY = Float(height) / 2
        halfHeight = max(4, (Float(height) / 2 - capRoom).rounded(.down))
        // Classic proportions are about twice as tall as wide.
        bulbHalfWidth = max(3, min(halfHeight * 0.56, maxHalfWidth, Float(width) / 2 - 2))
        // Two or three cells wide whatever the grain size, so the stream stays a thin trickle.
        neckHalfWidth = 1.15
        neckLength = 1.0
    }

    public var top: Float { centerY - halfHeight }
    public var bottom: Float { centerY + halfHeight }

    /// The inner half-width of the glass at row coordinate `y`, or `nil` beyond the bulbs.
    public func halfWidth(atY y: Float) -> Float? {
        let t = abs(y - centerY) / halfHeight
        guard t <= 1 else { return nil }
        if t <= shoulder {
            // A slow start out of the neck makes a funnel rather than a cone.
            let s = sinf(Float.pi / 2 * t / shoulder)
            return neckHalfWidth + (bulbHalfWidth - neckHalfWidth) * powf(s, 1.35)
        }
        // Past the shoulder the bulb rounds off towards the flat end under the cap.
        let s = (t - shoulder) / (1 - shoulder)
        return bulbHalfWidth * (1 - 0.32 * s * s)
    }

    /// The glass outline as a closed path in cell units, slightly outside the open cells.
    public func outline(inset: Float = -0.5, samples: Int = 96) -> CGPath {
        let path = CGMutablePath()
        var right: [CGPoint] = []
        var left: [CGPoint] = []
        for i in 0...samples {
            let y = top + (bottom - top) * Float(i) / Float(samples)
            let half = (halfWidth(atY: y) ?? 0) - inset
            right.append(CGPoint(x: CGFloat(centerX + half), y: CGFloat(y)))
            left.append(CGPoint(x: CGFloat(centerX - half), y: CGFloat(y)))
        }
        path.addLines(between: right + left.reversed())
        path.closeSubpath()
        return path
    }

    /// One side of the glass from top to bottom, for drawing highlights along the curve.
    public func profile(side: Float, inset: Float = 0, samples: Int = 96) -> [CGPoint] {
        (0...samples).map { i in
            let y = top + (bottom - top) * Float(i) / Float(samples)
            let half = (halfWidth(atY: y) ?? 0) - inset
            return CGPoint(x: CGFloat(centerX + side * half), y: CGFloat(y))
        }
    }
}
