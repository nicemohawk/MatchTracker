// HeatmapSection.swift
// MatchTracker

import SwiftUI
import MapKit
import MatchTrackerKit

struct HeatmapSection: View {
    @ObservedObject var detail: MatchDetailModel
    let analytics: MatchAnalytics
    @State private var showSatellite = false

    var body: some View {
        VStack(spacing: 12) {
            Toggle(isOn: $showSatellite) {
                Label("Overlay on satellite", systemImage: "globe.americas.fill")
            }
            .font(.subheadline)

            if showSatellite {
                SatelliteHeatmapOverlay(rectangle: analytics.rectangle, heatmap: analytics.heatmap)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                PitchHeatmapCanvas(heatmap: analytics.heatmap)
                    .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
                    .background(Color.green.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }

            HeatmapLegend()
        }
    }
}

/// Green pitch + alpha/color-ramped heatmap cells + white markings, aspect-correct.
struct PitchHeatmapCanvas: View {
    let heatmap: HeatmapGrid

    var body: some View {
        Canvas { context, size in
            let rect = SoccerPitch.fittedRect(in: size, padding: 6)

            // Turf.
            context.fill(Path(rect), with: .color(Color(red: 0.20, green: 0.55, blue: 0.25)))

            // Heatmap cells.
            if heatmap.columns > 0 && heatmap.rows > 0 {
                let cellWidth = rect.width / CGFloat(heatmap.columns)
                let cellHeight = rect.height / CGFloat(heatmap.rows)
                for row in 0..<heatmap.rows {
                    for column in 0..<heatmap.columns {
                        let value = heatmap[column, row]
                        guard value > 0.01 else { continue }
                        let cellRect = CGRect(
                            x: rect.minX + CGFloat(column) * cellWidth,
                            y: rect.minY + CGFloat(row) * cellHeight,
                            width: cellWidth + 0.5, height: cellHeight + 0.5
                        )
                        context.fill(Path(cellRect), with: .color(HeatColor.color(for: value)))
                    }
                }
            }

            var markingsContext = context
            SoccerPitch.draw(in: &markingsContext, rect: rect, lineColor: .white.opacity(0.9))
        }
    }
}

/// Draws the heatmap warped onto the field polygon over a non-interactive satellite map.
struct SatelliteHeatmapOverlay: View {
    let rectangle: OrientedRectangle
    let heatmap: HeatmapGrid

    var body: some View {
        MapReader { proxy in
            Map(initialPosition: .region(rectangle.mapRegion), interactionModes: []) {
                MapPolygon(coordinates: rectangle.coordinateRing)
                    .stroke(.white, lineWidth: 2)
                    .foregroundStyle(.white.opacity(0.05))
            }
            .mapStyle(.imagery)
            .overlay {
                Canvas { context, _ in
                    guard heatmap.columns > 0, heatmap.rows > 0, rectangle.corners.count == 4 else { return }
                    for row in 0..<heatmap.rows {
                        for column in 0..<heatmap.columns {
                            let value = heatmap[column, row]
                            guard value > 0.05 else { continue }
                            let quad = cellQuad(column: column, row: row, proxy: proxy)
                            guard let path = quad else { continue }
                            context.fill(path, with: .color(HeatColor.color(for: value)))
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func cellQuad(column: Int, row: Int, proxy: MapProxy) -> Path? {
        let u0 = CGFloat(column) / CGFloat(heatmap.columns)
        let u1 = CGFloat(column + 1) / CGFloat(heatmap.columns)
        let v0 = CGFloat(row) / CGFloat(heatmap.rows)
        let v1 = CGFloat(row + 1) / CGFloat(heatmap.rows)
        let corners = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
        var points: [CGPoint] = []
        for (u, v) in corners {
            let coordinate = bilerp(u: u, v: v).clCoordinate
            guard let point = proxy.convert(coordinate, to: .local) else { return nil }
            points.append(point)
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    /// Bilinear interpolation of the rectangle's corner ring to a normalized (u,v) point.
    private func bilerp(u: CGFloat, v: CGFloat) -> Coordinate2D {
        let c = rectangle.corners
        func mix(_ a: Coordinate2D, _ b: Coordinate2D, _ t: CGFloat) -> Coordinate2D {
            Coordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * Double(t),
                         longitude: a.longitude + (b.longitude - a.longitude) * Double(t))
        }
        let top = mix(c[0], c[1], u)
        let bottom = mix(c[3], c[2], u)
        return mix(top, bottom, v)
    }
}

struct HeatmapLegend: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Low").font(.caption2).foregroundStyle(.secondary)
            LinearGradient(
                colors: [.clear, .yellow, .orange, .red],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 8)
            .clipShape(Capsule())
            Text("High").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Transparent → yellow → red ramp for heatmap intensity.
enum HeatColor {
    static func color(for value: Double) -> Color {
        let clamped = min(1, max(0, value))
        let alpha = 0.15 + 0.75 * clamped
        if clamped < 0.5 {
            let t = clamped / 0.5
            return Color(red: 1, green: 1 - 0.35 * t, blue: 0).opacity(alpha)
        } else {
            let t = (clamped - 0.5) / 0.5
            return Color(red: 1, green: 0.65 * (1 - t), blue: 0).opacity(alpha)
        }
    }
}
