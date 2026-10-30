import HourGlassCore
import SwiftUI

/// Where the sand sits in the view: the grid's size in cells and how big a cell is on screen.
/// It's worked out from the view's size and the settings alone, so the glass and the wooden frame
/// can be drawn once for a layout instead of with every frame of sand.
struct SandLayout: Equatable {
    var viewSize: CGSize
    var scale: CGFloat
    var grain: GrainSize
    var mode: SandMode
    /// The grid, in cells.
    var columns: Int
    var rows: Int
    /// The size of a cell in points.
    var cellSize: CGFloat
    /// Where the grid's top-left corner sits in the view, in points.
    var origin: CGPoint

    init(size: CGSize, scale: CGFloat, grain: GrainSize, mode: SandMode) {
        viewSize = size
        self.scale = scale
        self.grain = grain
        self.mode = mode
        cellSize = CGFloat(grain.rawValue) / scale
        // The sandbox fills the screen. The hourglass stands below the row with the settings
        // button and the clock, and keeps clear of the button in the bottom corner.
        let top = Self.hourglassTop(for: size)
        let area = mode == .sandbox
            ? CGRect(origin: .zero, size: size)
            : CGRect(x: 0, y: top, width: size.width, height: size.height - top - 3)
        columns = max(0, Int(area.width / cellSize))
        rows = max(0, Int(area.height / cellSize))
        origin = .zero
        if mode == .hourglass && columns >= 3 && rows >= 3 {
            // Only as wide as the glass: the wall either side never changes, and narrower is less to
            // simulate and draw every frame.
            columns = Container.hourglassWidth(fitting: columns, height: rows, capRoom: capRoom,
                                               maxHalfWidth: maxHalfWidth)
        }
        origin = CGPoint(x: area.minX + (area.width - CGFloat(columns) * cellSize) / 2,
                         y: area.minY + (area.height - CGFloat(rows) * cellSize) / 2)
    }

    /// Where the hourglass's area starts, below the settings button and the clock.
    static func hourglassTop(for size: CGSize) -> CGFloat {
        max(44, size.height * 0.2)
    }

    /// Hourglass only: cells to leave above and below the glass for its caps.
    var capRoom: Float { Float((SandDrawing.Frame.capHeight + 1) / cellSize) }

    /// Hourglass only: the widest the bulbs may be, in cells from the middle, keeping clear of the
    /// button in the bottom corner.
    var maxHalfWidth: Float {
        let buttonRoom: CGFloat = 52
        return Float((viewSize.width / 2 - buttonRoom - SandDrawing.Frame.reach) / cellSize)
    }

    /// Big enough to hold some sand.
    var isUsable: Bool { viewSize.width > 10 && viewSize.height > 10 && columns >= 3 && rows >= 3 }

    /// The grid in the view, in points.
    var gridRect: CGRect {
        CGRect(x: origin.x, y: origin.y, width: CGFloat(columns) * cellSize, height: CGFloat(rows) * cellSize)
    }

    /// The point the hourglass turns about: the middle of its grid.
    var turnAnchor: UnitPoint {
        UnitPoint(x: gridRect.midX / viewSize.width, y: gridRect.midY / viewSize.height)
    }
}
