// PositionSection.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

struct PositionSection: View {
    @ObservedObject var detail: MatchDetailModel
    let analytics: MatchAnalytics

    /// Low-opacity match heatmap laid under the position pitch — the position content stays the hero.
    @State private var showHeatmapUnderlay = false
    /// Inline post-match position editor (multi-select) expansion.
    @State private var isEditing = false
    @State private var draftPositions: Set<ReportedPosition> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The Position section's semantic accent (see `Theme.sectionTint`) — tints the "on" chips.
    private let accent = Theme.sectionTint("Position")

    private var estimate: PositionEstimate { analytics.position }

    /// Player-reported positions from the record (nil/empty = never edited, so the auto-detected
    /// estimate reads as primary).
    private var reported: [ReportedPosition] { detail.record?.reportedPositions ?? [] }
    private var hasReported: Bool { !reported.isEmpty }
    private var canEdit: Bool { detail.record != nil }

    /// Curated multi-select palette: keeper + left/center/right across the three outfield lines.
    /// Mirrors the app's existing position vocabulary (`PositionBadge` label helpers).
    private static let options: [ReportedPosition] = [
        ReportedPosition(role: .goalkeeper),
        ReportedPosition(role: .defender, side: .left),
        ReportedPosition(role: .defender, side: .center),
        ReportedPosition(role: .defender, side: .right),
        ReportedPosition(role: .midfielder, side: .left),
        ReportedPosition(role: .midfielder, side: .center),
        ReportedPosition(role: .midfielder, side: .right),
        ReportedPosition(role: .forward, side: .left),
        ReportedPosition(role: .forward, side: .center),
        ReportedPosition(role: .forward, side: .right)
    ]

    var body: some View {
        VStack(spacing: 18) {
            controlChips

            PositionPitch(estimate: estimate,
                          heatmapUnderlay: showHeatmapUnderlay ? analytics.heatmap : nil)
                .aspectRatio(SoccerPitch.aspect, contentMode: .fit)
                .background(Theme.pitchTurfBottom)
                .overlay(alignment: .topLeading) { positionChip.padding(14) }
                .fullBleed()

            if isEditing {
                positionEditor
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }

            ThirdsBars(shares: thirdShares)
        }
    }

    // MARK: - Control chips

    /// Compact capsule chips (the app's chip idiom): "Heatmap" toggles the transparent underlay,
    /// "Edit" opens the multi-select position editor. Edit is disabled for record-less matches,
    /// which have nowhere to persist an override.
    private var controlChips: some View {
        HStack(spacing: 8) {
            toggleChip(title: "Heat", systemImage: "flame.fill", isOn: showHeatmapUnderlay,
                       identifier: "position-heatmap-underlay") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { showHeatmapUnderlay.toggle() }
            }
            toggleChip(title: isEditing ? "Done" : "Edit", systemImage: "pencil", isOn: isEditing,
                       identifier: "position-edit", disabled: !canEdit) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    if isEditing {
                        isEditing = false
                    } else {
                        draftPositions = Set(reported)
                        isEditing = true
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func toggleChip(title: String, systemImage: String, isOn: Bool, identifier: String,
                            disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            guard !disabled else { return }
            Haptics.selection()
            action()
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
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Floating position chip

    /// Floated large over the top-left of the pitch on a glass chip. Shows the player-reported
    /// positions as the hero when edited, with the auto estimate as secondary context; otherwise
    /// the auto estimate is the hero.
    @ViewBuilder
    private var positionChip: some View {
        if hasReported { reportedChip } else { detectedChip }
    }

    private var detectedChip: some View {
        HStack(spacing: 12) {
            PositionBadge(role: estimate.role, side: estimate.side, confidence: estimate.confidence)
                .scaleEffect(1.4)
                .frame(width: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(PositionBadge.fullName(role: estimate.role, side: estimate.side))
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Text("Confidence \(Int(estimate.confidence * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .glassChip()
    }

    private var reportedChip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Played")
                    .font(.caption2.weight(.semibold)).textCase(.uppercase)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(reported, id: \.self) { position in
                        Text(PositionBadge.abbreviation(role: position.role, side: position.side ?? .center))
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(Theme.chipFill(position.role.tint), in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.chipStroke(position.role.tint), lineWidth: 1))
                    }
                }
            }
            Text("Detected: \(PositionBadge.fullName(role: estimate.role, side: estimate.side)) · \(Int(estimate.confidence * 100))%")
                .font(.caption).foregroundStyle(.secondary)
        }
        .glassChip()
    }

    // MARK: - Editor

    private var positionEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Positions Played").font(.system(.headline, design: .rounded))
                Text("Select every position you played this match.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(Self.options, id: \.self) { option in
                    editorChip(option)
                }
            }

            HStack(spacing: 12) {
                Button(action: clearToAuto) {
                    Text("Clear to Auto")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 16).frame(minHeight: 40)
                        .background(Capsule().fill(Theme.surfaceElevated))
                        .overlay(Capsule().strokeBorder(Theme.surfaceStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!hasReported && draftPositions.isEmpty)
                .opacity((!hasReported && draftPositions.isEmpty) ? 0.4 : 1)

                Spacer(minLength: 0)

                Button(action: save) {
                    Text("Save")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                        .foregroundStyle(draftPositions.isEmpty ? Color.primary : Color.black)
                        .padding(.horizontal, 22).frame(minHeight: 40)
                        .background(Capsule().fill(draftPositions.isEmpty ? Theme.surfaceElevated : accent))
                        .overlay(Capsule().strokeBorder(draftPositions.isEmpty ? Theme.surfaceStroke : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(draftPositions.isEmpty)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.surfaceStroke, lineWidth: 1))
    }

    private func editorChip(_ option: ReportedPosition) -> some View {
        let isSelected = draftPositions.contains(option)
        return Button {
            Haptics.selection()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                if isSelected { draftPositions.remove(option) } else { draftPositions.insert(option) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                Text(Self.label(for: option))
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? option.role.tint : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10).frame(minHeight: 40)
            .background(Capsule().fill(isSelected ? Theme.chipFill(option.role.tint) : Theme.surfaceElevated))
            .overlay(Capsule().strokeBorder(isSelected ? Theme.chipStroke(option.role.tint) : Theme.surfaceStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Concise, idiomatic football name for an editor chip ("Left Back", "Center Mid", "Striker") —
    /// mirrors how position labels read on a team sheet and keeps the chips from truncating.
    private static func label(for position: ReportedPosition) -> String {
        switch position.role {
        case .goalkeeper: return "Goalkeeper"
        case .defender:
            switch position.side ?? .center {
            case .left: return "Left Back"; case .center: return "Center Back"; case .right: return "Right Back"
            }
        case .midfielder:
            switch position.side ?? .center {
            case .left: return "Left Mid"; case .center: return "Center Mid"; case .right: return "Right Mid"
            }
        case .forward:
            switch position.side ?? .center {
            case .left: return "Left Wing"; case .center: return "Striker"; case .right: return "Right Wing"
            }
        }
    }

    // MARK: - Persistence

    private func save() {
        guard var record = detail.record else { closeEditor(); return }
        let ordered = Self.options.filter { draftPositions.contains($0) }
        record.reportedPositions = ordered.isEmpty ? nil : ordered
        persist(record)
        Haptics.impact(.light)
        closeEditor()
    }

    private func clearToAuto() {
        draftPositions = []
        guard var record = detail.record else { closeEditor(); return }
        record.reportedPositions = nil
        persist(record)
        closeEditor()
    }

    private func closeEditor() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { isEditing = false }
    }

    /// Writes through the store's persist path (disk + summary/analytics refresh) when wired,
    /// falling back to a local record refresh for a standalone model.
    private func persist(_ record: MatchRecord) {
        if let persist = detail.persist { persist(record) } else { detail.updateRecord(record) }
    }

    /// Share of positional occupancy across defensive / middle / attacking thirds (long axis).
    private var thirdShares: [Double] {
        let heatmap = analytics.heatmap
        guard heatmap.columns > 0, heatmap.rows > 0 else { return [0, 0, 0] }
        var thirds = [0.0, 0.0, 0.0]
        for column in 0..<heatmap.columns {
            let third = min(2, column * 3 / heatmap.columns)
            for row in 0..<heatmap.rows {
                thirds[third] += heatmap[column, row]
            }
        }
        let total = thirds.reduce(0, +)
        guard total > 0 else { return [0, 0, 0] }
        return thirds.map { $0 / total }
    }
}

private extension View {
    /// Ultra-thin glass capsule/card used by the floating position chip so it stays legible over turf.
    func glassChip(cornerRadius: CGFloat = 16) -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
            )
    }
}

/// Mini pitch with the mean point and per-period points, optionally over a transparent heatmap underlay.
struct PositionPitch: View {
    let estimate: PositionEstimate
    /// When set, the match heatmap is drawn under the markings at low opacity so the position dots
    /// stay the hero. Reuses `HeatColor` (the shared heatmap ramp) — no recomputation.
    var heatmapUnderlay: HeatmapGrid? = nil

    var body: some View {
        Canvas { context, size in
            let rect = SoccerPitch.fittedRect(in: size, padding: 8)
            SoccerPitch.fillTurf(&context, rect: rect)

            if let grid = heatmapUnderlay, grid.columns > 0, grid.rows > 0 {
                var heat = context
                heat.opacity = 0.33   // "quite transparent" — the position content stays the hero
                let cellWidth = rect.width / CGFloat(grid.columns)
                let cellHeight = rect.height / CGFloat(grid.rows)
                for row in 0..<grid.rows {
                    for column in 0..<grid.columns {
                        let value = grid[column, row]
                        guard value > 0.01 else { continue }
                        let cellRect = CGRect(
                            x: rect.minX + CGFloat(column) * cellWidth,
                            y: rect.minY + CGFloat(row) * cellHeight,
                            width: cellWidth + 0.5, height: cellHeight + 0.5
                        )
                        heat.fill(Path(cellRect), with: .color(HeatColor.color(for: value)))
                    }
                }
            }

            var pitch = context
            SoccerPitch.draw(in: &pitch, rect: rect)

            func place(_ point: CGPoint) -> CGPoint {
                CGPoint(x: rect.minX + CGFloat(point.x) * rect.width,
                        y: rect.minY + CGFloat(point.y) * rect.height)
            }

            // Per-period points (smaller, semi-transparent) with connecting order labels.
            for (index, point) in estimate.periodMeanPoints.enumerated() {
                let center = place(point)
                let dot = CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
                context.fill(Path(ellipseIn: dot), with: .color(estimate.role.tint.opacity(0.55)))
                context.draw(Text("\(index + 1)").font(.caption2.bold()).foregroundColor(.white), at: center)
            }

            // Mean point (large).
            let mean = place(estimate.meanPoint)
            let ring = CGRect(x: mean.x - 11, y: mean.y - 11, width: 22, height: 22)
            context.fill(Path(ellipseIn: ring), with: .color(estimate.role.tint))
            context.stroke(Path(ellipseIn: ring), with: .color(.white), lineWidth: 2)
        }
    }
}

struct ThirdsBars: View {
    let shares: [Double]
    private let labels = ["Defensive", "Middle", "Attacking"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share of Thirds").font(.system(.title3, design: .rounded).weight(.bold))
            ForEach(Array(shares.enumerated()), id: \.offset) { index, share in
                HStack(spacing: 12) {
                    Text(labels[index]).font(.subheadline).frame(width: 86, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.surfaceStroke)
                            Capsule().fill(Theme.pace)
                                .frame(width: geometry.size.width * share)
                        }
                    }
                    .frame(height: 16)
                    Text("\(Int(share * 100))%")
                        .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                        .frame(width: 54, alignment: .trailing)
                }
            }
        }
    }
}
