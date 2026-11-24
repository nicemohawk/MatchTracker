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
                context.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [SurfacePalette.pitchTop, SurfacePalette.pitchBottom]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            drawHeat(in: &context, rect: rect)
            drawMarkings(in: &context, rect: rect.insetBy(dx: 1, dy: 1))
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(Self.sentence(for: heat))
    }

    private func drawHeat(in context: inout GraphicsContext, rect: CGRect) {
        guard let heat, heat.columns > 0, heat.rows > 0 else { return }
        let cell = CGSize(width: rect.width / CGFloat(heat.columns), height: rect.height / CGFloat(heat.rows))
        context.drawLayer { layer in
            // Cells blend into one field of heat instead of a grid of tiles.
            layer.addFilter(.blur(radius: min(cell.width, cell.height) * 0.6))
            for row in 0..<heat.rows {
                for column in 0..<heat.columns where heat[column, row] > 0.02 {
                    let value = heat[column, row]
                    let cellRect = CGRect(x: rect.minX + CGFloat(column) * cell.width,
                                          y: rect.minY + CGFloat(row) * cell.height,
                                          width: cell.width, height: cell.height).insetBy(dx: -0.5, dy: -0.5)
                    layer.fill(Path(cellRect), with: .color(color(for: value)))
                }
            }
        }
    }

    private func color(for value: Double) -> Color {
        if monochrome { return .white.opacity(0.15 + 0.75 * value) }
        let opacity = min(0.92, 0.08 + 1.3 * value)
        // Emerald to amber to rose, as in the app's heatmap.
        let t = value < 0.5 ? value * 2 : (value - 0.5) * 2
        return value < 0.5
            ? Color(red: 0.188 + 0.812 * t, green: 0.820 - 0.196 * t, blue: 0.345 - 0.306 * t).opacity(opacity)
            : Color(red: 1, green: 0.624 - 0.408 * t, blue: 0.039 + 0.334 * t).opacity(opacity)
    }

    private func drawMarkings(in context: inout GraphicsContext, rect: CGRect) {
        let metersToPoints = rect.width / 105
        var path = Path(roundedRect: rect, cornerRadius: 7, style: .continuous)
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
