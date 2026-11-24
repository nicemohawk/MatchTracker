import SwiftUI
import MatchTrackerKit

/// A small pitch with where you played on it. Markings are only what reads at this size. In the
/// tinted and clear Home Screen styles the turf drops out and heat becomes opacity.
struct PitchThumbnail: View {
    let heat: HeatmapGrid?
    var monochrome = false

    static let aspectRatio: CGFloat = 105 / 68

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            if !monochrome {
                context.fill(Path(rect), with: .color(SurfacePalette.cloth))
            }
            drawHeat(in: &context, rect: rect)
            drawMarkings(in: &context, rect: rect.insetBy(dx: 1, dy: 1))
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(Self.sentence(for: heat))
    }

    private func drawHeat(in context: inout GraphicsContext, rect: CGRect) {
        guard let heat, heat.columns > 0, heat.rows > 0 else { return }
        // Three points a stitch: finer than that shimmers.
        let columns = Int(rect.width / 3.6)
        guard columns > 0 else { return }
        let width = rect.width / CGFloat(columns), rise = width * Knit.rise
        let yarns = Knit.yarns.map { _ in CGMutablePath() }
        for row in 0..<Int((rect.height / rise).rounded(.up)) {
            for column in 0..<columns {
                let level = level(in: heat, x: (CGFloat(column) + 0.5) / CGFloat(columns), y: (CGFloat(row) + 0.5) * rise / rect.height)
                guard let yarn = Knit.yarn(for: Float(level.squareRoot())) else { continue }
                Knit.addStitch(to: yarns[yarn], column: column, row: row, width: width)
            }
        }
        for (index, path) in yarns.enumerated() {
            let color = monochrome ? Color.white.opacity([0.2, 0.4, 0.65, 0.95][index]) : Color(cgColor: Knit.yarns[index])
            context.fill(Path(path), with: .color(color))
        }
    }

    /// Between cells rather than at them, or the cloth would show the grid.
    private func level(in heat: HeatmapGrid, x: CGFloat, y: CGFloat) -> Double {
        let column = min(max(Double(x) * Double(heat.columns) - 0.5, 0), Double(heat.columns - 1))
        let row = min(max(Double(y) * Double(heat.rows) - 0.5, 0), Double(heat.rows - 1))
        let left = Int(column), top = Int(row)
        let right = min(left + 1, heat.columns - 1), bottom = min(top + 1, heat.rows - 1)
        let across = column - Double(left), down = row - Double(top)
        return (heat[left, top] * (1 - across) + heat[right, top] * across) * (1 - down)
            + (heat[left, bottom] * (1 - across) + heat[right, bottom] * across) * down
    }

    private func drawMarkings(in context: inout GraphicsContext, rect: CGRect) {
        let metersToPoints = rect.width / 105
        var path = Path(rect)
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        let radius = 9.15 * metersToPoints
        path.addEllipse(in: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2))
        let box = CGSize(width: 16.5 * metersToPoints, height: 40.32 * metersToPoints)
        path.addRect(CGRect(x: rect.minX, y: rect.midY - box.height / 2, width: box.width, height: box.height))
        path.addRect(CGRect(x: rect.maxX - box.width, y: rect.midY - box.height / 2, width: box.width, height: box.height))
        context.stroke(path, with: .color(.white.opacity(monochrome ? 0.5 : 0.45)), lineWidth: 1)
    }

    /// "You were mostly in the middle third, on the left." Direction of attack isn't known here, so
    /// it isn't claimed.
    static func sentence(for heat: HeatmapGrid?) -> String {
        guard let heat, heat.columns > 0, heat.rows > 0, heat.cells.contains(where: { $0 > 0 }) else {
            return "No position data"
        }
        var total = 0.0, x = 0.0, y = 0.0
        for row in 0..<heat.rows {
            for column in 0..<heat.columns {
                let value = heat[column, row]
                total += value
                x += value * (Double(column) + 0.5) / Double(heat.columns)
                y += value * (Double(row) + 0.5) / Double(heat.rows)
            }
        }
        x /= total
        y /= total
        let along = x < 1 / 3.0 ? "one end" : x > 2 / 3.0 ? "the other end" : "the middle"
        let across = y < 0.4 ? " near one touchline" : y > 0.6 ? " near the far touchline" : ""
        return "Heatmap. Mostly in \(along) of the pitch\(across)."
    }
}
