// MatchesView.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit

struct MatchesView: View {
    /// True while no detail is pushed; drives the settings circle's root-only visibility.
    @Binding var isAtRoot: Bool
    /// Mirrors the tab bar's `.onScrollDown` minimize state: true after a downward scroll, false
    /// on any upward scroll or near the top. The settings circle hides alongside the minimized bar.
    @Binding var isScrolledDown: Bool
    @EnvironmentObject private var matches: MatchStore
    @EnvironmentObject private var fields: FieldsModel
    @Environment(LiveMatchStore.self) private var liveMatches
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(BacklogImporter.self) private var backlogImporter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showingImport = false
    @State private var navigationPath: [UUID] = []

    init(isAtRoot: Binding<Bool> = .constant(true),
         isScrolledDown: Binding<Bool> = .constant(false)) {
        _isAtRoot = isAtRoot
        _isScrolledDown = isScrolledDown
    }
#if DEBUG
    @State private var isGeneratingDemo = false
#endif

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if matches.matches.isEmpty && !liveMatches.isLive {
                    emptyState
                } else {
                    // ScrollView + LazyVStack (not List) so cards get scroll transitions and a
                    // pressed-state scale — List swallows both.
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if showBacklogTeaser {
                                backlogTeaser
                            }
                            // On iOS 26+ the live match rides in the tab bar's bottom accessory
                            // (see RootTabView), so this in-list card would be a duplicate affordance.
                            if #unavailable(iOS 26.0), liveMatches.isLive {
                                liveCard
                            }
                            ForEach(matches.matches) { summary in
                                NavigationLink(value: summary.id) {
                                    MatchRow(summary: summary)
                                }
                                .buttonStyle(PressableCardStyle())
                                .scrollTransition(.interactive(timingCurve: .easeOut),
                                                  axis: .vertical) { content, phase in
                                    content
                                        .opacity(phase.isIdentity ? 1 : 0.55)
                                        .scaleEffect(phase.isIdentity ? 1 : 0.965)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        // iPad / wide split: keep the card column a readable measure, centered,
                        // instead of full-bleed cards spanning the whole canvas.
                        .readableWidth()
                    }
                    .scrollIndicators(.automatic)
                    .modifier(ScrollDownTracker(isScrolledDown: $isScrolledDown))
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Matches")
            .navigationDestination(for: UUID.self) { id in
                if let summary = matches.matches.first(where: { $0.id == id }) {
                    MatchDetailView(summary: summary)
                }
            }
            .toolbar {
                // Coach live dashboard (team feature), most useful at iPad width.
                if horizontalSizeClass == .regular, entitlements.entitledToTeam,
                   !SettingsStore.shared.teamCode.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            CoachDashboardView(teamCode: SettingsStore.shared.teamCode)
                        } label: {
                            Image(systemName: "field.of.view.wide")
                        }
                    }
                }
            }
            .refreshable { await matches.refresh() }
            .overlay {
                if matches.isLoading && matches.matches.isEmpty {
                    ProgressView()
                }
            }
            .task { await backlogImporter.scanIfNeeded() }
            .sheet(isPresented: $showingImport) { BacklogImportView() }
        }
        .onChange(of: navigationPath) { _, path in
            isAtRoot = path.isEmpty
        }
    }

    /// Quiet upsell for the historic-backlog import: shown once there's a meaningful backlog of
    /// workout-only matches and the player hasn't imported yet. Scan + teaser are free; the batch
    /// import itself is gated inside the sheet.
    private var showBacklogTeaser: Bool {
        backlogImporter.pendingCount >= 5 && !backlogImporter.hasImported
    }

    private var backlogTeaser: some View {
        Button {
            Haptics.selection()
            showingImport = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundStyle(Theme.turf)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(backlogImporter.pendingCount) past matches found")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(.primary)
                    Text("Import your history to build fields & season trends")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "sparkles")
                    .font(.footnote.bold())
                    .foregroundStyle(Theme.signal)
            }
            .padding(16)
            .themedCard()
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.chipStroke(Theme.turf), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Watch-streamed match in progress: jump to the live sideline dashboard.
    private var liveCard: some View {
        NavigationLink {
            LiveMatchView(store: liveMatches, projector: liveProjector)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Theme.heart)
                    .frame(width: 12, height: 12)
                    .glow(Theme.heart, radius: 6)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LIVE · Match in progress")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.turf)
                    if let update = liveMatches.latest {
                        Text("\(update.usGoals ?? 0)–\(update.themGoals ?? 0) · \(String(format: "%.1f km", update.distanceMeters / 1000))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.3), value: update.distanceMeters)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.turfFlow, lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }

    /// Field projector for the live position dot, resolved from streamed points.
    private var liveProjector: FieldProjector? {
        let coordinates = liveMatches.recentPoints.suffix(30).map(\.coordinate)
        guard !coordinates.isEmpty,
              let field = fields.store.bestMatch(for: Array(coordinates)) else { return nil }
        return FieldProjector(rectangle: field.rectangle)
    }

    /// Welcoming themed empty state: a small pitch illustration, an on-brand prompt to record on
    /// the watch, and — in DEBUG only — an inline sample-match generator (mirrors Settings' demo
    /// tools) so testers can populate the list without an Apple Watch.
    private var emptyState: some View {
        VStack(spacing: 22) {
            Canvas { context, size in
                let rect = SoccerPitch.fittedRect(in: size, padding: 6)
                SoccerPitch.fillTurf(&context, rect: rect)
                SoccerPitch.draw(in: &context, rect: rect)
            }
            .frame(width: 220, height: 143)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.surfaceStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("No matches yet")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text("Record a match on your Apple Watch and it will appear here — with heatmaps, runs, and your workrate.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 40)
            }

            if let error = matches.loadError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

#if DEBUG
            Button {
                addSampleMatch()
            } label: {
                HStack(spacing: 8) {
                    if isGeneratingDemo {
                        ProgressView().tint(Theme.turf)
                    } else {
                        Image(systemName: "plus.circle.fill")
                    }
                    Text(isGeneratingDemo ? "Adding…" : "Add a sample match")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                }
                .foregroundStyle(Theme.turf)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(Theme.chipFill(Theme.turf), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.chipStroke(Theme.turf), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isGeneratingDemo)
#endif
        }
        .padding()
        // Center the invite in a readable column on iPad rather than stranding it in a wide canvas.
        .readableWidth()
    }

#if DEBUG
    /// Generates one synthetic match through the real analysis pipeline, then refreshes the list —
    /// a minimal inline replica of SettingsView's developer generator.
    private func addSampleMatch() {
        isGeneratingDemo = true
        Task {
            let factory = DemoMatchFactory(
                healthKit: matches.healthKit,
                fields: fields,
                teamCode: SettingsStore.shared.teamCode.isEmpty ? "TEST01" : SettingsStore.shared.teamCode
            )
            try? await factory.generateMatch(daysAgo: 1)
            await matches.refresh()
            isGeneratingDemo = false
        }
    }
#endif
}

/// Tracks whether the user has scrolled down (the gesture that minimizes the iOS 26 tab bar) so
/// the settings circle can hide alongside the shrinking bar. No-op before iOS 18 — the minimize
/// behavior it mirrors only exists on iOS 26.
private struct ScrollDownTracker: ViewModifier {
    @Binding var isScrolledDown: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { old, new in
                // Match the bar's own behavior: minimize past a bit of downward travel,
                // restore on any upward scroll or at the top.
                if new > old + 1, new > 60 {
                    if !isScrolledDown { isScrolledDown = true }
                } else if new < old - 1 || new <= 10 {
                    if isScrolledDown { isScrolledDown = false }
                }
            }
        } else {
            content
        }
    }
}

/// Card press feedback: a quick settle-down scale, mirroring what a UICollectionView highlight
/// gives for free. Applied to the match cards now that they live in a ScrollView.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// One list row: date, field name, duration, distance, mini position badge.
struct MatchRow: View {
    let summary: MatchSummary
    @EnvironmentObject private var store: MatchStore
    @State private var position: (role: PositionRole, side: PositionSide, confidence: Double)?
    @State private var fieldName: String?
    /// Whether a GPS route was recorded — nil until the lazy detail load resolves it.
    @State private var hasRoute: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.startDate, format: .dateTime.weekday().month().day().hour().minute())
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    HStack(spacing: 6) {
                        Text(fieldName ?? "Unknown field")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        formatBadge
                        recordingKindBadge
                    }
                }
                Spacer()
                if let score {
                    Text(score)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(scoreTint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.chipFill(scoreTint), in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.chipStroke(scoreTint), lineWidth: 1))
                } else if let position {
                    PositionBadge(role: position.role, side: position.side, confidence: position.confidence)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                metric(MatchFormat.distance(summary.distanceMeters), "Distance", Theme.pace)
                metric(MatchFormat.shortDuration(summary.duration), "Duration", Theme.signal)
                Spacer()
                if score != nil, let position {
                    PositionBadge(role: position.role, side: position.side, confidence: position.confidence)
                }
            }
        }
        .padding(16)
        .themedCard()
        .task { await loadBadge() }
    }

    /// A small glyph + label for non-default match formats (pickup / indoor). `.match` shows nothing.
    @ViewBuilder
    private var formatBadge: some View {
        switch summary.record?.format ?? .match {
        case .match:
            EmptyView()
        case .smallSided:
            formatLabel(icon: "figure.cooldown", text: "Pickup")
        case .indoor:
            formatLabel(icon: "house", text: "Indoor")
        }
    }

    /// How the match was captured: a route glyph when a GPS track exists, nothing otherwise.
    /// (Indoor sessions already carry the house glyph via `formatBadge`, so they're excluded here —
    /// one icon per row, never two.)
    @ViewBuilder
    private var recordingKindBadge: some View {
        if summary.record?.format != .indoor, hasRoute == true {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.caption2)
                .foregroundStyle(Theme.pace)
                .accessibilityLabel("GPS route recorded")
        }
    }

    private func formatLabel(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func metric(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label).captionLabel()
        }
    }

    /// "us–them" from logged goal events, when any exist.
    private var score: String? {
        guard let events = summary.record?.events, !events.isEmpty else { return nil }
        let us = events.filter { $0.kind == .goalForUs || $0.kind == .goalMine }.count
        let them = events.filter { $0.kind == .goalAgainstUs }.count
        guard us > 0 || them > 0 else { return nil }
        return "\(us)–\(them)"
    }

    private var scoreTint: Color {
        guard let events = summary.record?.events else { return Theme.bench }
        let us = events.filter { $0.kind == .goalForUs || $0.kind == .goalMine }.count
        let them = events.filter { $0.kind == .goalAgainstUs }.count
        if us > them { return Theme.turf }
        if us < them { return Theme.loss }
        return Theme.bench
    }

    private func loadBadge() async {
        let detail = store.detailModel(for: summary)
        await detail.load()
        hasRoute = !detail.track.isEmpty
        if let analytics = detail.analytics {
            // Indoor sessions carry only a placeholder position estimate — don't badge one.
            if summary.record?.format != .indoor {
                position = (analytics.position.role, analytics.position.side, analytics.position.confidence)
            }
            fieldName = analytics.fieldName
        } else if let fieldID = summary.record?.fieldID {
            // Record-only match: resolve the field name directly (no analytics available).
            fieldName = store.fields.field(id: fieldID)?.name
        }
    }
}
