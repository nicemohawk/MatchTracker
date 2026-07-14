// HeatmapSection.swift
// MatchTracker

import SwiftUI
import MapKit
import MatchTrackerKit

struct HeatmapSection: View {
    @ObservedObject var detail: MatchDetailModel
    let analytics: MatchAnalytics
    @EnvironmentObject private var store: MatchStore
    @State private var showSatellite = false
    @State private var compareWithSeason = false

    var body: some View {
        VStack(spacing: 12) {
            Toggle(isOn: $showSatellite) {
                Label("Overlay on satellite", systemImage: "globe.americas.fill")
            }
            .font(.subheadline)

            Toggle(isOn: $compareWithSeason) {
                Label("Compare with season average", systemImage: "square.2.layers.3d")
            }
            .font(.subheadline)
            .disabled(showSatellite)

            if showSatellite {
                SatelliteHeatmapOverlay(rectangle: analytics.rectangle, heatmap: analytics.heatmap)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                PitchHeatmapCanvas(heatmap: analytics.heatmap,
                                   comparison: compareWithSeason ? seasonAverage : nil)
                    .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
                    .background(Theme.pitchTurfBottom, in: RoundedRectangle(cornerRadius: 16))
            }

            if compareWithSeason && !showSatellite {
                if seasonAverage == nil {
                    Text("Play more matches to compare — no other analyzed matches yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    comparisonLegend
                }
            }

            HeatmapLegend()
        }
    }

    /// Cell-wise average of every OTHER analyzed match's heatmap (cached only — never loads).
    private var seasonAverage: HeatmapGrid? {
        let grids = store.cachedHeatmaps(excluding: detail.matchIdentifier)
            .filter { $0.columns == analytics.heatmap.columns && $0.rows == analytics.heatmap.rows }
        guard !grids.isEmpty else { return nil }
        var averaged = grids[0]
        let count = Double(grids.count)
        for index in averaged.cells.indices {
            averaged.cells[index] = grids.reduce(0) { $0 + $1.cells[index] } / count
        }
        let peak = averaged.cells.max() ?? 1
        if peak > 0 {
            for index in averaged.cells.indices { averaged.cells[index] /= peak }
        }
        return averaged
    }

    private var comparisonLegend: some View {
        HStack(spacing: 14) {
            Label("This match", systemImage: "square.fill")
                .foregroundStyle(Theme.sprint)
            Label("Season average", systemImage: "square.fill")
                .foregroundStyle(Theme.signal)
        }
        .font(.caption2)
    }
}

/// Green pitch + alpha/color-ramped heatmap cells + white markings, aspect-correct.
/// An optional `comparison` grid (e.g. season average) renders beneath in cool blue.
struct PitchHeatmapCanvas: View {
    let heatmap: HeatmapGrid
    var comparison: HeatmapGrid?

    var body: some View {
        Canvas { context, size in
            let rect = SoccerPitch.fittedRect(in: size, padding: 6)

            // Turf.
            SoccerPitch.fillTurf(&context, rect: rect)

            // Comparison underlay (season average): cool cyan so the warm ramp reads on top.
            if let comparison, comparison.columns > 0, comparison.rows > 0 {
                let cellWidth = rect.width / CGFloat(comparison.columns)
                let cellHeight = rect.height / CGFloat(comparison.rows)
                for row in 0..<comparison.rows {
                    for column in 0..<comparison.columns {
                        let value = comparison[column, row]
                        guard value > 0.05 else { continue }
                        let cellRect = CGRect(
                            x: rect.minX + CGFloat(column) * cellWidth,
                            y: rect.minY + CGFloat(row) * cellHeight,
                            width: cellWidth + 0.5, height: cellHeight + 0.5
                        )
                        context.fill(Path(cellRect),
                                     with: .color(Theme.signal.opacity(0.15 + 0.5 * min(1, value))))
                    }
                }
            }

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
            SoccerPitch.draw(in: &markingsContext, rect: rect)
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
                colors: [.clear, Theme.goal, Theme.sprint, Theme.heart],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 8)
            .clipShape(Capsule())
            Text("High").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Deep transparent → lime → hot coral ramp for heatmap intensity, tuned for dark turf with a
/// slight glow (higher alpha at the hot end). Matches the Theme accent set (goal → sprint → heart).
enum HeatColor {
    static func color(for value: Double) -> Color {
        let clamped = min(1, max(0, value))
        let alpha = 0.18 + 0.78 * clamped
        if clamped < 0.5 {
            let t = clamped / 0.5
            // goal (lime) → sprint (magenta-orange)
            return Color(red: 0.78 + 0.22 * t,
                         green: 1.0 - 0.52 * t,
                         blue: 0.30 - 0.06 * t).opacity(alpha)
        } else {
            let t = (clamped - 0.5) / 0.5
            // sprint → heart (coral)
            return Color(red: 1.0,
                         green: 0.48 - 0.12 * t,
                         blue: 0.24 + 0.24 * t).opacity(alpha)
        }
    }
}
