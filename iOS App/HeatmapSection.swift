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
    @State private var comparisonMode: ComparisonMode = .compare
    @State private var isHoldingCompare = false
    @State private var hintPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One-time discoverability: the "Hold to flip" pill shows until the user's first successful
    /// hold, then never again (persisted). Key name kept stable across builds.
    @AppStorage("heatmapFlipHintShown") private var flipHintDismissed = false

    /// The Heatmap section's semantic accent (see `Theme.sectionTint`) — used to tint the active
    /// display chips so they read as "on" the way every other chip in the app does.
    private let accent = Theme.sprint

    /// The two ways to read a match against its season average.
    private enum ComparisonMode: String, CaseIterable, Identifiable {
        case compare = "Compare"
        case difference = "Difference"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 12) {
            displayChips

            if showSatellite {
                SatelliteHeatmapOverlay(rectangle: analytics.rectangle, heatmap: analytics.heatmap)
                    .frame(height: 360)
                    .fullBleed()
                HeatmapLegend()
            } else if compareWithSeason {
                if let seasonAverage {
                    comparisonContent(seasonAverage: seasonAverage)
                } else {
                    singleMatchPitch
                    Text("Play more matches to compare — no other analyzed matches yet.")
                        .font(.caption).foregroundStyle(.secondary)
                    HeatmapLegend()
                }
            } else {
                singleMatchPitch
                HeatmapLegend()
            }
        }
        .onChange(of: showSatellite) { _, _ in isHoldingCompare = false }
        .onChange(of: comparisonMode) { _, _ in
            isHoldingCompare = false
            Haptics.selection()
        }
    }

    // MARK: - Display chips

    /// Compact capsule chips (the app's chip idiom) replacing the old full-width toggle band, which
    /// read as a muddy olive block. Same bindings/behavior: "Satellite" mirrors `showSatellite`,
    /// "Compare" mirrors `compareWithSeason` and is disabled while satellite is on.
    private var displayChips: some View {
        HStack(spacing: 8) {
            displayChip(title: "Satellite", systemImage: "globe.americas.fill", isOn: showSatellite) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { showSatellite.toggle() }
            }
            displayChip(title: "Compare", systemImage: "square.2.layers.3d",
                        isOn: compareWithSeason, disabled: showSatellite) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { compareWithSeason.toggle() }
            }
            Spacer(minLength: 0)
        }
    }

    private func displayChip(title: String, systemImage: String, isOn: Bool,
                             disabled: Bool = false, toggle: @escaping () -> Void) -> some View {
        Button {
            guard !disabled else { return }
            Haptics.selection()
            toggle()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(isOn ? accent : Color.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(Capsule().fill(isOn ? Theme.chipFill(accent) : Theme.surfaceElevated))
                .overlay(Capsule().strokeBorder(isOn ? Theme.chipStroke(accent) : Theme.surfaceStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    private var singleMatchPitch: some View {
        PitchHeatmapCanvas(render: .heat(analytics.heatmap))
            .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
            .background(Theme.pitchTurfBottom)
            .fullBleed()
    }

    // MARK: - Comparison UX

    @ViewBuilder
    private func comparisonContent(seasonAverage: HeatmapGrid) -> some View {
        modeControl

        switch comparisonMode {
        case .compare:
            comparePitch(seasonAverage: seasonAverage)
            HeatmapLegend()
        case .difference:
            if let diff = analytics.heatmap.difference(from: seasonAverage) {
                PitchHeatmapCanvas(render: .difference(diff))
                    .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
                    .background(Theme.pitchTurfBottom)
                    .fullBleed()
            }
            DivergingHeatmapLegend()
        }
    }

    /// Two theme chips selecting how the comparison reads.
    private var modeControl: some View {
        HStack(spacing: 8) {
            ForEach(ComparisonMode.allCases) { mode in
                modeChip(mode)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modeChip(_ mode: ComparisonMode) -> some View {
        let isSelected = comparisonMode == mode
        return Button {
            guard comparisonMode != mode else { return }
            withAnimation(.easeInOut(duration: 0.2)) { comparisonMode = mode }
        } label: {
            Text(mode.rawValue)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(isSelected ? Color.black : Color.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(Capsule().fill(isSelected ? Theme.sprint : Theme.surfaceElevated))
                .overlay(Capsule().strokeBorder(isSelected ? .clear : Theme.surfaceStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Before/after style: the pitch shows THIS MATCH; press-and-hold crossfades to the SEASON
    /// AVERAGE while held. Both renders use the identical warm ramp so the eye can diff them.
    private func comparePitch(seasonAverage: HeatmapGrid) -> some View {
        ZStack {
            PitchHeatmapCanvas(render: .heat(analytics.heatmap))
            // Incoming season layer scales 0.98→1 as it crossfades, so the flip feels physical.
            PitchHeatmapCanvas(render: .heat(seasonAverage))
                .opacity(isHoldingCompare ? 1 : 0)
                .scaleEffect(isHoldingCompare ? 1 : 0.98)

            captionCapsule
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(10)

            if !flipHintDismissed && !isHoldingCompare {
                flipHintPill
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 14)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
        .background(Theme.pitchTurfBottom)
        .fullBleed()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in setHolding(true) }
                .onEnded { _ in setHolding(false) }
        )
        .accessibilityElement()
        .accessibilityLabel("Heatmap comparison")
        .accessibilityValue(isHoldingCompare ? "Showing season average" : "Showing this match")
        .accessibilityHint("Touch and hold to show the season average")
    }

    /// Flipping label on the pitch — tinted differently for each state.
    private var captionCapsule: some View {
        let label = isHoldingCompare ? "SEASON AVERAGE" : "THIS MATCH"
        let tint = isHoldingCompare ? Theme.signal : Theme.sprint
        return Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
            .id(isHoldingCompare)
            .transition(.opacity)
    }

    /// Glass discoverability pill overlaid on the pitch — the hold-to-flip gesture is otherwise
    /// invisible. Gently pulses (unless Reduce Motion) and is dismissed forever on first hold.
    private var flipHintPill: some View {
        Label("Hold to flip", systemImage: "hand.tap.fill")
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(accent.opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            .scaleEffect(hintPulse ? 1.06 : 1.0)
            .opacity(hintPulse ? 1.0 : 0.82)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    hintPulse = true
                }
            }
    }

    private func setHolding(_ holding: Bool) {
        guard holding != isHoldingCompare else { return }
        Haptics.selection()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isHoldingCompare = holding }
        if holding && !flipHintDismissed {
            withAnimation(.easeInOut(duration: 0.25)) { flipHintDismissed = true }
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
}

/// How a `PitchHeatmapCanvas` paints its cells: a single warm heatmap, or a diverging
/// difference render. The turf and markings are identical either way.
enum PitchHeatmapRender {
    case heat(HeatmapGrid)
    case difference(HeatmapDifference)
}

/// Green pitch + ramped heatmap cells + white markings, aspect-correct. Parameterized by a
/// `PitchHeatmapRender` so the same canvas backs single-match, before/after, and diff views.
struct PitchHeatmapCanvas: View {
    let render: PitchHeatmapRender

    var body: some View {
        Canvas { context, size in
            let rect = SoccerPitch.fittedRect(in: size, padding: 6)
            SoccerPitch.fillTurf(&context, rect: rect)

            switch render {
            case .heat(let heatmap):
                Self.drawHeat(heatmap, into: &context, rect: rect)
            case .difference(let difference):
                Self.drawDifference(difference, into: &context, rect: rect)
            }

            var markingsContext = context
            SoccerPitch.draw(in: &markingsContext, rect: rect)
        }
    }

    private static func drawHeat(_ heatmap: HeatmapGrid, into context: inout GraphicsContext, rect: CGRect) {
        guard heatmap.columns > 0, heatmap.rows > 0 else { return }
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

    private static func drawDifference(_ difference: HeatmapDifference, into context: inout GraphicsContext, rect: CGRect) {
        guard difference.columns > 0, difference.rows > 0 else { return }
        let cellWidth = rect.width / CGFloat(difference.columns)
        let cellHeight = rect.height / CGFloat(difference.rows)
        for row in 0..<difference.rows {
            for column in 0..<difference.columns {
                let value = difference[column, row]
                guard abs(value) >= DiffColor.deadband else { continue }
                let color = DiffColor.color(for: value, maximumMagnitude: difference.maximumMagnitude)
                let cellRect = CGRect(
                    x: rect.minX + CGFloat(column) * cellWidth,
                    y: rect.minY + CGFloat(row) * cellHeight,
                    width: cellWidth + 0.5, height: cellHeight + 0.5
                )
                context.fill(Path(cellRect), with: .color(color))
            }
        }
    }
}

/// Satellite mode: the camera rotates so the field's long axis is horizontal, the match heatmap is
/// painted onto the imagery as georeferenced `MapPolygon` cells (projection-correct — they cannot
/// drift from the pitch), and the full pitch line set is drawn over them as map-space polylines.
struct SatelliteHeatmapOverlay: View {
    let rectangle: OrientedRectangle
    let heatmap: HeatmapGrid

    var body: some View {
        Map(initialPosition: cameraPosition, interactionModes: []) {
            // Heat cells — each grid cell as a quad in real-world coordinates, so it stays welded
            // to the pitch regardless of camera heading/zoom.
            ForEach(heatCells) { cell in
                MapPolygon(coordinates: cell.coordinates)
                    .foregroundStyle(cell.color)
            }
            // Pitch markings (touchlines, halfway, center circle, penalty + goal boxes) as
            // map-space polylines aligned to the field rectangle.
            ForEach(Array(outlinePolylines.enumerated()), id: \.offset) { _, line in
                MapPolyline(coordinates: line)
                    .stroke(Theme.pitchLines, lineWidth: 2)
            }
        }
        .mapStyle(.imagery)
    }

    /// Rotate the camera so the field's long axis runs horizontally: heading = long-axis bearing
    /// + 90° puts the perpendicular (short axis) "up", laying the long axis left-to-right. Distance
    /// frames the pitch with margin — the long axis is the binding dimension on screen.
    private var cameraPosition: MapCameraPosition {
        let heading = (rectangle.headingDegrees + 90).truncatingRemainder(dividingBy: 360)
        let distance = max(rectangle.lengthMeters, rectangle.widthMeters * 1.9) * 1.55
        return .camera(MapCamera(centerCoordinate: rectangle.center.clCoordinate,
                                 distance: distance, heading: heading))
    }

    // MARK: - Heat cells

    private struct HeatCell: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
    }

    private var heatCells: [HeatCell] {
        guard heatmap.columns > 0, heatmap.rows > 0, rectangle.corners.count == 4 else { return [] }
        var cells: [HeatCell] = []
        for row in 0..<heatmap.rows {
            for column in 0..<heatmap.columns {
                let value = heatmap[column, row]
                guard value > 0.05 else { continue }
                let u0 = CGFloat(column) / CGFloat(heatmap.columns)
                let u1 = CGFloat(column + 1) / CGFloat(heatmap.columns)
                let v0 = CGFloat(row) / CGFloat(heatmap.rows)
                let v1 = CGFloat(row + 1) / CGFloat(heatmap.rows)
                let coordinates = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
                    .map { fieldPoint($0.0, $0.1) }
                cells.append(HeatCell(id: row * heatmap.columns + column,
                                      coordinates: coordinates,
                                      color: HeatColor.color(for: value)))
            }
        }
        return cells
    }

    // MARK: - Pitch outline (map-space)

    /// The SoccerPitch line set expressed in normalized field space, then mapped to coordinates.
    /// Proportions are relative to the actual field dimensions so the markings sit correctly on
    /// the imagery even when the pitch isn't a regulation 105×68.
    private var outlinePolylines: [[CLLocationCoordinate2D]] {
        guard rectangle.corners.count == 4,
              rectangle.lengthMeters > 0, rectangle.widthMeters > 0 else { return [] }
        let length = CGFloat(rectangle.lengthMeters)
        let width = CGFloat(rectangle.widthMeters)
        var lines: [[(CGFloat, CGFloat)]] = []

        // Outer boundary + halfway line.
        lines.append([(0, 0), (1, 0), (1, 1), (0, 1), (0, 0)])
        lines.append([(0.5, 0), (0.5, 1)])

        // Center circle (9.15 m radius) — an ellipse in normalized space (length ≠ width scale).
        let ru = 9.15 / length, rv = 9.15 / width
        lines.append(ellipse(centerU: 0.5, centerV: 0.5, radiusU: ru, radiusV: rv))

        // Penalty (16.5 m × 40.32 m) and goal (5.5 m × 18.32 m) boxes, both ends.
        for end in [true, false] {
            lines.append(box(depthMeters: 16.5, heightMeters: 40.32,
                             length: length, width: width, leftSide: end))
            lines.append(box(depthMeters: 5.5, heightMeters: 18.32,
                             length: length, width: width, leftSide: end))
        }

        return lines.map { line in line.map { fieldPoint($0.0, $0.1) } }
    }

    /// A goal-line box `depthMeters` deep and `heightMeters` tall, centered on the short axis.
    private func box(depthMeters: CGFloat, heightMeters: CGFloat,
                     length: CGFloat, width: CGFloat, leftSide: Bool) -> [(CGFloat, CGFloat)] {
        let du = depthMeters / length
        let halfH = (heightMeters / width) / 2
        let u0: CGFloat = leftSide ? 0 : 1
        let u1: CGFloat = leftSide ? du : 1 - du
        let vTop = 0.5 - halfH, vBottom = 0.5 + halfH
        return [(u0, vTop), (u1, vTop), (u1, vBottom), (u0, vBottom), (u0, vTop)]
    }

    private func ellipse(centerU: CGFloat, centerV: CGFloat,
                         radiusU: CGFloat, radiusV: CGFloat, segments: Int = 48) -> [(CGFloat, CGFloat)] {
        (0...segments).map { step in
            let angle = 2 * CGFloat.pi * CGFloat(step) / CGFloat(segments)
            return (centerU + radiusU * cos(angle), centerV + radiusV * sin(angle))
        }
    }

    /// Bilinear interpolation of the rectangle's corner ring to a normalized (u,v) field point.
    /// u runs along the long axis (corners[0]→corners[1]), v along the short axis (corners[0]→corners[3]).
    private func fieldPoint(_ u: CGFloat, _ v: CGFloat) -> CLLocationCoordinate2D {
        let c = rectangle.corners
        func mix(_ a: Coordinate2D, _ b: Coordinate2D, _ t: CGFloat) -> Coordinate2D {
            Coordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * Double(t),
                         longitude: a.longitude + (b.longitude - a.longitude) * Double(t))
        }
        let top = mix(c[0], c[1], u)
        let bottom = mix(c[3], c[2], u)
        return mix(top, bottom, v).clCoordinate
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

/// Diverging legend for Difference mode: cool (less than usual) → clear → warm (more than usual).
/// The words carry the meaning so color is never the sole encoding.
struct DivergingHeatmapLegend: View {
    var body: some View {
        VStack(spacing: 6) {
            LinearGradient(
                colors: [Theme.pace, Theme.signal, .clear, Theme.sprint, Theme.heart],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 8)
            .clipShape(Capsule())
            HStack {
                Text("Less than usual").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("More than usual").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Deep transparent → emerald → amber → hot rose ramp for heatmap intensity, tuned for dark turf
/// (higher alpha at the hot end). Anchored to the Theme accent set (turf → sprint → heart), with a
/// hot core of #FF375F.
enum HeatColor {
    static func color(for value: Double) -> Color {
        let clamped = min(1, max(0, value))
        let alpha = 0.18 + 0.78 * clamped
        if clamped < 0.5 {
            let t = clamped / 0.5
            // turf (emerald #30D158) → sprint (amber-orange #FF9F0A)
            return Color(red: 0.188 + 0.812 * t,
                         green: 0.820 - 0.196 * t,
                         blue: 0.345 - 0.306 * t).opacity(alpha)
        } else {
            let t = (clamped - 0.5) / 0.5
            // sprint (#FF9F0A) → heart (rose #FF375F)
            return Color(red: 1.0,
                         green: 0.624 - 0.408 * t,
                         blue: 0.039 + 0.334 * t).opacity(alpha)
        }
    }
}

/// Diverging ramp for the Difference render. Positive (more time here than usual) reads warm
/// (sprint → heart), negative (less than usual) reads cool (signal → pace). Cells within the
/// dead-band are fully transparent; opacity scales with |value| / maximumMagnitude. Theme colors
/// are trait-adaptive so both schemes stay legible.
enum DiffColor {
    /// |value| below this is treated as "same as usual" and not drawn.
    static let deadband = 0.04

    static func color(for value: Double, maximumMagnitude: Double) -> Color {
        let magnitude = abs(value)
        guard magnitude >= deadband else { return .clear }
        let intensity = min(1, magnitude / max(maximumMagnitude, HeatmapDifference.magnitudeEpsilon))
        let alpha = 0.15 + 0.75 * intensity
        if value > 0 {
            return (intensity < 0.6 ? Theme.sprint : Theme.heart).opacity(alpha)
        } else {
            return (intensity < 0.6 ? Theme.signal : Theme.pace).opacity(alpha)
        }
    }
}
