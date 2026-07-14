// FieldsDrawer.swift
// MatchTracker

import SwiftUI
import CoreLocation
import MatchTrackerKit

/// The persistent bottom drawer for the Fields tab, rendered as a custom snapping overlay INSIDE
/// the tab's content (not a `.sheet`) so the tab bar below stays visible and tappable — the
/// AllTrails pattern. It holds every action and all content: a compact summary + nearest-field
/// hint at the peek, an actions row (Scan This Area / Add Field / Seed Nearby), a highlighted
/// "Detected" group for live proposals, an animated scanning row, and the field list sorted by
/// distance from the map center. Each field reads as an AllTrails-style place card (source badge,
/// distance, confidence). The detail, accept-proposal, and add-field flows are presented from here
/// as real sheets so they nest cleanly above the always-on drawer.
///
/// Snapping vs. scrolling: the drag-to-resize gesture lives ONLY on the grabber + summary header,
/// while the list below sits in a `ScrollView`, so the two never fight. At the peek snap the scroll
/// view is collapsed and disabled (only the summary shows); at the half snap it scrolls normally.
struct FieldsDrawer: View {
    let fields: [FieldModel]
    let proposals: [OrientedRectangle]
    let isScanning: Bool
    let mapCenter: CLLocationCoordinate2D?

    @Binding var selectedFieldID: UUID?
    @Binding var pendingProposal: IdentifiedRectangle?
    @Binding var showingAddField: Bool

    let onScan: () -> Void
    let onSeed: () -> Void
    let onSelectField: (FieldModel) -> Void
    let onDismissProposals: () -> Void

    @EnvironmentObject private var fieldsModel: FieldsModel
    @Environment(NearbyFieldSeeder.self) private var seeder

    /// Fields with fewer than this many confirming observations render as "unconfirmed" — a dashed
    /// motif that matches the map's dashed low-confidence polygons and the detail sheet's language.
    private let confirmedThreshold = 3

    /// The two snap states, matching the old `.presentationDetents([.height(96), .medium])`.
    private enum Snap { case peek, half }
    @State private var snap: Snap = .peek
    /// Live finger travel during a resize drag (negative = dragging up / taller). Reset to 0 on end.
    @State private var dragOffset: CGFloat = 0

    /// Height of the collapsed peek — roughly one headline line plus the drag hint. Shared with
    /// `FieldsView` so the map's control column can sit just above it.
    static let peekHeight: CGFloat = 96

    /// On iOS 26 the floating Liquid Glass tab bar does NOT contribute a bottom safe-area inset
    /// (content is expected to flow beneath it), so the drawer surface reaches the physical screen
    /// bottom and its lower edge would hide behind the pills. This allowance keeps the drawer's
    /// CONTENT above the bar while the glass surface still flows underneath. Pre-26 the tab bar
    /// insets normally and no allowance is needed.
    static var tabBarAllowance: CGFloat {
        if #available(iOS 26.0, *) { return 70 } else { return 0 }
    }

    /// Total height the peek occupies from the screen bottom — what overlays (the map control
    /// column) must clear.
    static var totalPeekClearance: CGFloat { peekHeight + tabBarAllowance }

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.height
            let peek = Self.peekHeight + Self.tabBarAllowance
            // Half snap ~45% of the available (safe-area) height, floored so it always clears peek.
            let half = max(available * 0.45, peek + 120)
            let base = snap == .peek ? peek : half
            let height = rubberBanded(base - dragOffset, lower: peek, upper: half)

            drawerBody(peek: peek, half: half,
                       progress: min(max((height - peek) / (half - peek), 0), 1))
                .frame(maxWidth: .infinity)
                .frame(height: height, alignment: .top)
                .modifier(DrawerGlass())
                // Pin to the bottom of the safe area; empty space above stays non-interactive so
                // the map behind it keeps receiving touches.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                // When the tab bar minimizes on scroll-down the bottom safe area (and thus the
                // available height) changes; animate the resize so the drawer glides instead of
                // jittering. Keyed on `available` only, so it never animates the drag itself.
                .animation(.spring(response: 0.35, dampingFraction: 0.9), value: available)
        }
        .sheet(item: selectedFieldBinding) { field in
            FieldDetailSheet(field: field)
        }
        .sheet(item: $pendingProposal) { proposal in
            AcceptProposalSheet(rectangle: proposal.rectangle)
        }
        .fullScreenCover(isPresented: $showingAddField) {
            AddFieldView()
        }
    }

    // MARK: - Drawer container

    /// Grabber + summary header (the resize handle) stacked over the scrollable content.
    /// `progress` is 0 at peek and 1 at half: the scrollable content fades in with expansion so the
    /// collapsed drawer shows only the summary — no partially-cut rows at the tab bar's edge.
    private func drawerBody(peek: CGFloat, half: CGFloat, progress: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 36, height: 5)
                    .accessibilityHidden(true)
                summary
                    .padding(.horizontal, 20)
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            // The whole header (grabber + summary + padding) is the drag target.
            .contentShape(Rectangle())
            .gesture(resizeGesture(peek: peek, half: half))

            scrollContent
                .opacity(progress)
        }
    }

    /// The browsable body. Disabled at the peek snap so a peek only ever shows the summary and the
    /// content-scroll gesture can't fight the resize drag.
    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if showEmptyInvite {
                    emptyInvite
                } else {
                    actions
                    if !proposals.isEmpty { detectedSection }
                    if isScanning { ScanningRow() }
                    if !fields.isEmpty { fieldList }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 44 + Self.tabBarAllowance)
        }
        .scrollContentBackground(.hidden)
        .scrollDisabled(snap == .peek)
    }

    /// Velocity-aware snapping with a light rubber band beyond the extremes.
    private func resizeGesture(peek: CGFloat, half: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                dragOffset = value.translation.height
            }
            .onEnded { value in
                let base = snap == .peek ? peek : half
                let currentHeight = base - value.translation.height
                let midpoint = (peek + half) / 2
                let velocity = value.velocity.height
                let target: Snap
                if velocity < -350 {
                    target = .half
                } else if velocity > 350 {
                    target = .peek
                } else {
                    target = currentHeight >= midpoint ? .half : .peek
                }
                if target != snap { Haptics.selection() }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    snap = target
                    dragOffset = 0
                }
            }
    }

    /// Resists travel past the peek/half bounds so an over-drag feels tethered, not hard-stopped.
    private func rubberBanded(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        if value < lower { return lower - (lower - value) * 0.35 }
        if value > upper { return upper + (value - upper) * 0.35 }
        return value
    }

    /// The dedicated empty state (with prominent action buttons) shows only when there is truly
    /// nothing to browse — no saved fields, no live proposals, and no scan in flight.
    private var showEmptyInvite: Bool {
        fields.isEmpty && proposals.isEmpty && !isScanning
    }

    // MARK: - Peek summary

    /// Compact enough to read cleanly at the 96pt peek detent: one headline line ("N fields ·
    /// nearest 400 m") over a quiet drag hint, so nothing clips before the drawer is expanded.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if fields.isEmpty {
                Text("No fields yet")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Walk a field or scan imagery to begin.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("^[\(fields.count) field](inflect: true)")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary)
                    if let nearest = nearestSummary {
                        Text("· \(nearest)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(isScanning ? "Scanning satellite imagery…" : "Swipe up to browse and manage fields.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "nearest 400 m" for the peek headline, or just the nearest field's name if the map center
    /// isn't known yet.
    private var nearestSummary: String? {
        guard let nearest = sortedFields.first else { return nil }
        if let center = mapCenter {
            return "nearest \(MatchFormat.distance(distance(nearest, from: center)))"
        }
        return "nearest \(nearest.name)"
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                scanButton
                Button { showingAddField = true } label: {
                    Label("Add Field", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.turf)
            }
            seedButton
        }
    }

    private var scanButton: some View {
        Button(action: onScan) {
            HStack(spacing: 6) {
                if isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "sparkle.magnifyingglass")
                }
                Text(isScanning ? "Scanning…" : "Scan This Area")
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)
        .tint(Theme.signal)
        .disabled(isScanning)
        .accessibilityLabel("Scan this area for fields")
    }

    private var seedButton: some View {
        Button(action: onSeed) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text(seeder.isScanning
                         ? "Seeding nearby… \(seeder.scannedTiles)/\(seeder.totalTiles)"
                         : "Seed Nearby Fields")
                    Spacer(minLength: 0)
                }
                .font(.subheadline.weight(.semibold))
                if seeder.isScanning {
                    ProgressView(value: Double(seeder.scannedTiles),
                                 total: Double(max(seeder.totalTiles, 1)))
                        .tint(Theme.turf)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .tint(Theme.pace)
        .disabled(seeder.isScanning)
        .accessibilityLabel("Seed nearby fields from satellite imagery")
    }

    // MARK: - Empty state

    private var emptyInvite: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                Image(systemName: "figure.walk.motion")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.turf)
                    .frame(width: 68, height: 68)
                    .background(Theme.chipFill(Theme.turf), in: Circle())
                    .overlay(Circle().strokeBorder(Theme.chipStroke(Theme.turf), lineWidth: 1))
                Text("No fields here yet")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Walk a field's touchline or scan satellite imagery to detect pitches around you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 10) {
                Button { showingAddField = true } label: {
                    Label("Add a Field", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.turf)

                Button(action: onScan) {
                    Label("Scan This Area", systemImage: "sparkle.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Theme.signal)

                seedButton
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.surfaceStroke, lineWidth: 1)
        )
    }

    // MARK: - Detected proposals

    private var detectedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeaderBar(title: "Detected", tint: FieldSource.satellite.color)
                Spacer()
                Button {
                    Haptics.selection()
                    onDismissProposals()
                } label: {
                    Text("Dismiss")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss all detected proposals")
            }
            ForEach(Array(proposals.enumerated()), id: \.offset) { _, proposal in
                proposalCard(proposal)
            }
        }
    }

    /// Each satellite proposal gets its own card: the satellite tint, a dashed border echoing the
    /// map's dashed proposal polygons, a turf Accept capsule, and a quiet Dismiss.
    private func proposalCard(_ proposal: OrientedRectangle) -> some View {
        let satellite = FieldSource.satellite.color
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                sourceTile(source: .satellite)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Possible pitch")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        SourceBadge(source: .satellite)
                        Text("\(Int(proposal.lengthMeters)) × \(Int(proposal.widthMeters)) m")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
            }
            HStack(spacing: 10) {
                Button {
                    Haptics.selection()
                    pendingProposal = IdentifiedRectangle(rectangle: proposal)
                } label: {
                    Text("Accept")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.turf)
                .clipShape(Capsule())

                Button {
                    Haptics.selection()
                    onDismissProposals()
                } label: {
                    Text("Dismiss")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered)
                .tint(Theme.bench)
                .clipShape(Capsule())
            }
        }
        .padding(14)
        .background(Theme.tintWash(satellite, dark: 0.14, light: 0.10),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.chipStroke(satellite),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
    }

    // MARK: - Field list

    private var fieldList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderBar(title: "Fields", tint: Theme.turf)
            ForEach(sortedFields) { field in
                Button {
                    Haptics.selection()
                    onSelectField(field)
                } label: {
                    fieldRow(field)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func fieldRow(_ field: FieldModel) -> some View {
        let isSelected = field.id == selectedFieldID
        let tint = field.source.color
        return HStack(spacing: 12) {
            sourceTile(source: field.source)
            VStack(alignment: .leading, spacing: 5) {
                Text(field.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    SourceBadge(source: field.source)
                    ConfidenceBadge(observationCount: field.observationCount,
                                    confirmedThreshold: confirmedThreshold)
                }
                Text("\(Int(field.rectangle.lengthMeters)) × \(Int(field.rectangle.widthMeters)) m")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if let distanceText = distanceText(for: field) {
                    Text(distanceText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? tint : .secondary)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? Theme.tintWash(tint, dark: 0.16, light: 0.10) : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Theme.chipStroke(tint) : Theme.surfaceStroke,
                              lineWidth: 1)
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    /// The leading rounded-square glyph tile, tinted to the field's source.
    private func sourceTile(source: FieldSource) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.chipFill(source.color))
            .frame(width: 38, height: 38)
            .overlay(
                Image(systemName: source.glyph)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(source.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.chipStroke(source.color), lineWidth: 1)
            )
    }

    // MARK: - Distance sorting

    private var sortedFields: [FieldModel] {
        guard let center = mapCenter else { return fields }
        return fields.sorted { distance($0, from: center) < distance($1, from: center) }
    }

    private func distance(_ field: FieldModel, from center: CLLocationCoordinate2D) -> CLLocationDistance {
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let point = CLLocation(latitude: field.rectangle.center.latitude,
                               longitude: field.rectangle.center.longitude)
        return point.distance(from: origin)
    }

    private func distanceText(for field: FieldModel) -> String? {
        guard let center = mapCenter else { return nil }
        return MatchFormat.distance(distance(field, from: center))
    }

    private var selectedFieldBinding: Binding<FieldModel?> {
        Binding(
            get: { selectedFieldID.flatMap { fieldsModel.field(id: $0) } },
            set: { selectedFieldID = $0?.id }
        )
    }
}

// MARK: - Drawer glass

/// The drawer's translucent surface: rounded top corners (24pt continuous), a glass material so the
/// map reads through slightly, tinted toward `Theme.background`, with a hairline top stroke. Uses
/// Liquid Glass on iOS 26 and an `.ultraThinMaterial` fallback earlier — matching the app's glass
/// language (see `MapControlGlass`).
private struct DrawerGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 24, bottomLeadingRadius: 0,
            bottomTrailingRadius: 0, topTrailingRadius: 24,
            style: .continuous
        )
        return Group {
            if #available(iOS 26.0, *) {
                content
                    .background(Theme.background.opacity(0.55), in: shape)
                    .glassEffect(.regular, in: shape)
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .background(Theme.background.opacity(0.6), in: shape)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.surfaceStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 16, y: -4)
    }
}

// MARK: - Source presentation

private extension FieldSource {
    /// AllTrails-style badge language: how each field was captured, from the user's point of view.
    var badgeName: String {
        switch self {
        case .trained: return "Walked"
        case .inferred: return "GPS"
        case .satellite: return "Satellite"
        case .community: return "Community"
        }
    }

    /// A small glyph for the leading source tile.
    var glyph: String {
        switch self {
        case .trained: return "figure.walk"
        case .inferred: return "location.fill"
        case .satellite: return "globe.americas.fill"
        case .community: return "person.2.fill"
        }
    }
}

/// A tinted capsule naming a field's source (walked / GPS / satellite / community).
private struct SourceBadge: View {
    let source: FieldSource

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(source.color)
                .frame(width: 6, height: 6)
            Text(source.badgeName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(source.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.chipFill(source.color), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.chipStroke(source.color), lineWidth: 1))
    }
}

/// A confidence hint that mirrors the map: unconfirmed geometry gets a dashed capsule, confirmed
/// geometry a solid one.
private struct ConfidenceBadge: View {
    let observationCount: Int
    let confirmedThreshold: Int

    private var isConfirmed: Bool { observationCount >= confirmedThreshold }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isConfirmed ? "checkmark.seal.fill" : "circle.dashed")
                .font(.system(size: 9, weight: .semibold))
            Text(isConfirmed ? "Confirmed" : "Unconfirmed")
                .font(.system(size: 11, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(
            Capsule().strokeBorder(
                Color.secondary.opacity(0.4),
                style: isConfirmed
                    ? StrokeStyle(lineWidth: 1)
                    : StrokeStyle(lineWidth: 1, dash: [3, 2])
            )
        )
    }
}

/// A radar-style scanning row shown while a satellite scan is in flight: the satellite glyph pulses
/// concentric rings instead of a bare spinner.
private struct ScanningRow: View {
    @State private var animate = false
    private let satellite = FieldSource.satellite.color

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                ForEach(0..<2, id: \.self) { index in
                    Circle()
                        .stroke(satellite.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 40, height: 40)
                        .scaleEffect(animate ? 1.7 : 0.7)
                        .opacity(animate ? 0 : 0.9)
                        .animation(
                            .easeOut(duration: 1.6)
                                .repeatForever(autoreverses: false)
                                .delay(Double(index) * 0.8),
                            value: animate
                        )
                }
                Circle()
                    .fill(Theme.chipFill(satellite))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(satellite)
                    )
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Scanning this area…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Looking for pitches in satellite imagery")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(14)
        .background(Theme.tintWash(satellite, dark: 0.12, light: 0.08),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.chipStroke(satellite),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .onAppear { animate = true }
        .accessibilityLabel("Scanning this area for fields")
    }
}
