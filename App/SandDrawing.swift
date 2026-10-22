import HourGlassCore
import SwiftUI

/// What's drawn around the sand: for the hourglass its glass, caps and posts, for the sandbox a
/// sheen on the screen. None of it changes from frame to frame, so it's drawn by views of its own
/// that SwiftUI redraws only when the layout changes, and the sand is just an image between them.
@MainActor
enum SandDrawing {
    /// Hourglass frame sizes, in points so they look the same at every grain size.
    enum Frame {
        static let capHeight: CGFloat = 14
        static let capOverhang: CGFloat = 5
        static let postWidth: CGFloat = 4.5
        static let postGap: CGFloat = 3.5
        /// How far the caps reach beyond the bulbs on either side.
        static var reach: CGFloat { capOverhang + postGap }
    }

    /// Where the hourglass's bottom cap sits in the view, for the countdown engraved on it.
    static func bottomCap(of glass: HourglassGeometry, layout: SandLayout) -> CGRect {
        let cell = layout.cellSize, origin = layout.origin
        let width = (CGFloat(glass.bulbHalfWidth) * cell + Frame.reach) * 2
        return CGRect(x: origin.x + CGFloat(glass.centerX) * cell - width / 2,
                      y: origin.y + CGFloat(glass.bottom) * cell,
                      width: width, height: Frame.capHeight)
    }

    /// `ctx` working in cell units, like the simulation, and the size of a point in them.
    static func cells(_ ctx: GraphicsContext, _ layout: SandLayout) -> (GraphicsContext, CGFloat) {
        var cells = ctx
        cells.translateBy(x: layout.origin.x, y: layout.origin.y)
        cells.scaleBy(x: layout.cellSize, y: layout.cellSize)
        return (cells, 1 / layout.cellSize)
    }

    // MARK: - Glass

    fileprivate static func drawGlassBack(_ ctx: inout GraphicsContext, _ glass: HourglassGeometry, point: CGFloat) {
        let outline = Path(glass.outline(inset: -0.6))
        ctx.fill(outline, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.07), .white.opacity(0.03), .white.opacity(0.06)]),
            startPoint: CGPoint(x: CGFloat(glass.centerX - glass.bulbHalfWidth), y: 0),
            endPoint: CGPoint(x: CGFloat(glass.centerX + glass.bulbHalfWidth), y: 0)))
    }

    fileprivate static func drawGlassFront(_ ctx: inout GraphicsContext, _ glass: HourglassGeometry, point: CGFloat) {
        let outline = Path(glass.outline(inset: -0.6))
        ctx.stroke(outline, with: .color(.white.opacity(0.42)), lineWidth: 1.1 * point)

        // Reflections: a bright streak down the left of each bulb, a faint one on the right.
        let span = glass.bottom - glass.top
        for (side, opacity, inset) in [(Float(-1), 0.34, Float(2.6) * Float(point)),
                                       (Float(1), 0.12, Float(3.2) * Float(point))] {
            let points = glass.profile(side: side, inset: inset * 2)
            for bulb in [0, 1] {
                // Skip the caps and the neck, where a highlight would look pinched.
                let from = glass.top + span * (bulb == 0 ? 0.06 : 0.62)
                let to = glass.top + span * (bulb == 0 ? 0.38 : 0.94)
                let segment = points.filter { Float($0.y) >= from && Float($0.y) <= to }
                guard segment.count > 1 else { continue }
                var path = Path()
                path.addLines(segment)
                ctx.stroke(path, with: .color(.white.opacity(opacity)),
                           style: StrokeStyle(lineWidth: 1.8 * point, lineCap: .round))
            }
        }
    }

    // MARK: - Wooden frame

    fileprivate static func drawFrame(_ ctx: inout GraphicsContext, _ glass: HourglassGeometry, point: CGFloat) {
        let cx = CGFloat(glass.centerX)
        let half = CGFloat(glass.bulbHalfWidth) + Frame.reach * point
        let capHeight = Frame.capHeight * point
        let top = CGFloat(glass.top), bottom = CGFloat(glass.bottom)

        let woodLight = Color(red: 0.62, green: 0.42, blue: 0.25)
        let woodMid = Color(red: 0.44, green: 0.28, blue: 0.16)
        let woodDark = Color(red: 0.25, green: 0.15, blue: 0.08)

        // Posts first, so the caps sit over their ends.
        let postX = CGFloat(glass.bulbHalfWidth) + Frame.postGap * point + Frame.postWidth * point / 2
        for side: CGFloat in [-1, 1] {
            let x = cx + side * postX
            let rect = CGRect(x: x - Frame.postWidth * point / 2, y: top - capHeight * 0.5,
                              width: Frame.postWidth * point, height: bottom - top + capHeight)
            let post = Path(roundedRect: rect, cornerRadius: Frame.postWidth * point / 2)
            ctx.fill(post, with: .linearGradient(
                Gradient(colors: [woodDark, woodLight, woodMid, woodDark]),
                startPoint: CGPoint(x: rect.minX, y: 0), endPoint: CGPoint(x: rect.maxX, y: 0)))
            // Turned beads along the post.
            for t in stride(from: CGFloat(0.18), through: 0.82, by: 0.32) {
                let y = top + (bottom - top) * t
                let bead = CGRect(x: rect.minX - point * 0.9, y: y - point * 2.2,
                                  width: rect.width + point * 1.8, height: point * 4.4)
                ctx.fill(Path(ellipseIn: bead), with: .linearGradient(
                    Gradient(colors: [woodDark, woodLight, woodDark]),
                    startPoint: CGPoint(x: bead.minX, y: 0), endPoint: CGPoint(x: bead.maxX, y: 0)))
            }
        }

        for isTop in [true, false] {
            let y = isTop ? top - capHeight : bottom
            let rect = CGRect(x: cx - half, y: y, width: half * 2, height: capHeight)
            let cap = Path(roundedRect: rect, cornerRadius: capHeight * 0.32)
            ctx.fill(cap, with: .linearGradient(
                Gradient(colors: [woodLight, woodMid, woodDark]),
                startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            // A bevel catching the light along the top edge, and a groove in the middle.
            var edge = Path()
            edge.move(to: CGPoint(x: rect.minX + capHeight * 0.3, y: rect.minY + point * 0.8))
            edge.addLine(to: CGPoint(x: rect.maxX - capHeight * 0.3, y: rect.minY + point * 0.8))
            ctx.stroke(edge, with: .color(.white.opacity(0.28)), lineWidth: point)
            var groove = Path()
            let gy = isTop ? rect.maxY - capHeight * 0.3 : rect.minY + capHeight * 0.3
            groove.move(to: CGPoint(x: rect.minX + point * 2, y: gy))
            groove.addLine(to: CGPoint(x: rect.maxX - point * 2, y: gy))
            ctx.stroke(groove, with: .color(.black.opacity(0.3)), lineWidth: point * 0.8)
        }
    }

    // MARK: - Sandbox

    /// A soft reflection across the top left, as if the sand were behind glass.
    fileprivate static func drawSheen(_ ctx: inout GraphicsContext, _ rect: CGRect) {
        var sheen = Path()
        sheen.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.32))
        sheen.addLine(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY))
        sheen.addLine(to: CGPoint(x: rect.minX + rect.width * 0.8, y: rect.minY))
        sheen.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.5))
        sheen.closeSubpath()
        ctx.fill(sheen, with: .linearGradient(
            Gradient(colors: [.white.opacity(0), .white.opacity(0.05), .white.opacity(0)]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.3),
            endPoint: CGPoint(x: rect.minX + rect.width * 0.45, y: rect.minY + rect.height * 0.05)))
    }
}

/// The glass behind the sand.
struct GlassBack: View {
    let glass: HourglassGeometry
    let layout: SandLayout

    var body: some View {
        Canvas { ctx, _ in
            var (cells, point) = SandDrawing.cells(ctx, layout)
            SandDrawing.drawGlassBack(&cells, glass, point: point)
        }
    }
}

/// The glass in front of the sand, with its highlights, and the wooden frame.
struct GlassFront: View {
    let glass: HourglassGeometry
    let layout: SandLayout

    var body: some View {
        Canvas { ctx, _ in
            var (cells, point) = SandDrawing.cells(ctx, layout)
            SandDrawing.drawGlassFront(&cells, glass, point: point)
            SandDrawing.drawFrame(&cells, glass, point: point)
        }
    }
}

/// The sandbox's sheen, as if the sand were behind glass.
struct Sheen: View {
    let rect: CGRect

    var body: some View {
        Canvas { ctx, _ in
            SandDrawing.drawSheen(&ctx, rect)
        }
    }
}

/// The palette's backdrop: a gradient with a vignette, behind the sand.
struct Backdrop: View {
    let palette: SandPalette

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: palette.backgroundTop), Color(hex: palette.backgroundBottom)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center,
                           startRadius: 60, endRadius: 190)
        }
        .ignoresSafeArea()
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
