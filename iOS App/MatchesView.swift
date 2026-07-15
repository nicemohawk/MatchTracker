// MatchesView.swift
// MatchTracker

import SwiftUI
import MatchTrackerKit
#if DEBUG
import os
#endif

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
    /// Precomputed month-grouped list model (see MatchListSupport). Rebuilt once per matches-array
    /// change via `.task(id:)`, never per row — the LazyVStack stays lazy.
    @State private var listData: MatchListData = .empty
    @State private var searchText = ""
    @State private var filter: MatchFilter = .all

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
                    // The empty state is only honest AFTER a refresh has completed returning zero.
                    // Before that — a first-ever launch with no persisted cache, still loading — show
                    // skeleton rows so the empty state can never flash while the history loads.
                    if matches.didCompleteInitialLoad {
                        emptyState
                    } else {
                        skeletonList
                    }
                } else {
                    matchList
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Matches")
            // Search over the precomputed haystacks (field, month/year, score, format, GPS).
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search matches")
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
            .task { await backlogImporter.scanIfNeeded() }
            // Rebuild the grouped precompute once per matches-array change (see MatchListData.build).
            .task(id: matchesSignature) {
                listData = MatchListData.build(matches: matches.matches, store: matches)
            }
            .sheet(isPresented: $showingImport) { BacklogImportView() }
        }
        .onChange(of: navigationPath) { _, path in
            isAtRoot = path.isEmpty
        }
    }

    /// Identity of the current matches array — count folded with every id — so the precompute
    /// rebuilds only when matches actually change (add / remove / reorder), not on every render.
    private var matchesSignature: Int {
        var hasher = Hasher()
        hasher.combine(matches.matches.count)
        for match in matches.matches { hasher.combine(match.id) }
        // Rebuild once when cold-cache rows reconcile into workout-backed ones (same id set), so the
        // precompute picks up authoritative summaries without waiting for an add/remove.
        hasher.combine(matches.reconcileToken)
        return hasher.finalize()
    }

    /// The month-sectioned list. A fixed filter chip row sits under the title; the scroll view below
    /// carries the backlog teaser, the pre-26 live card, and the pinned-header month sections. Card
    /// design, press style, scroll transitions, and the badge cache are unchanged — this restructures
    /// around the existing row, it doesn't redesign it.
    private var matchList: some View {
        let sections = listData.sections(filter: filter, query: searchText)
        // ScrollView + LazyVStack (not List) so cards get scroll transitions and a pressed-state
        // scale — List swallows both. Headers are NOT pinned: they float as inline text (see
        // MatchSectionHeader) instead of the old full-width opaque "year bars".
        return ScrollView {
            LazyVStack(spacing: 12) {
                if showBacklogTeaser {
                    backlogTeaser
                }
                // On iOS 26+ the live match rides in the tab bar's bottom accessory (see
                // RootTabView), so this in-list card would be a duplicate affordance.
                if #unavailable(iOS 26.0), liveMatches.isLive {
                    liveCard
                }

                if sections.isEmpty {
                    filteredEmptyState
                } else {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                NavigationLink(value: item.id) {
                                    MatchRow(summary: item.summary, dateLabel: item.dateLabel)
                                }
                                .buttonStyle(PressableCardStyle())
                                .scrollTransition(.interactive(timingCurve: .easeOut),
                                                  axis: .vertical) { content, phase in
                                    content
                                        .opacity(phase.isIdentity ? 1 : 0.55)
                                        .scaleEffect(phase.isIdentity ? 1 : 0.965)
                                }
                            }
                        } header: {
                            MatchSectionHeader(title: section.title, detail: section.detail)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            // iPad / wide split: keep the card column a readable measure, centered, instead of
            // full-bleed cards spanning the whole canvas.
            .readableWidth()
        }
        .scrollIndicators(.automatic)
        .modifier(ScrollDownTracker(isScrolledDown: $isScrolledDown))
        // Pin the filter chip row as a glass overlay; the scroll content insets below it but scrolls
        // UNDER it (the material blurs the cards passing behind), so there's no hard clip edge.
        .safeAreaInset(edge: .top, spacing: 0) {
            MatchFilterBar(data: listData, selection: $filter)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .modifier(GlassListHeader())
        }
    }

    /// First-ever cold launch, no persisted cache yet, refresh still running: redacted placeholder
    /// cards in the list idiom so the screen reads as "your matches are loading", never as the empty
    /// invite. Non-interactive and non-scrolling — it's a loading state, not content.
    private var skeletonList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<7, id: \.self) { _ in
                    SkeletonMatchRow()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .readableWidth()
        }
        .scrollDisabled(true)
        .allowsHitTesting(false)
        .accessibilityLabel("Loading matches")
    }

    /// Shown when an active search/filter matches nothing: a quiet one-liner and a reset.
    private var filteredEmptyState: some View {
        VStack(spacing: 12) {
            Text("No matches match your filters.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Haptics.selection()
                filter = .all
                searchText = ""
            } label: {
                Text("Clear filters")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Theme.turf)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Theme.chipFill(Theme.turf), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.chipStroke(Theme.turf), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
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

/// Glass treatment for the pinned filter-chip header: a translucent material so the match cards
/// remain visible (blurred) as they scroll behind it, with a soft progressive edge below rather
/// than a hard seam. iOS 26 gets the Liquid Glass bar effect; earlier systems fall back to
/// `.ultraThinMaterial`, the app's established glass idiom.
private struct GlassListHeader: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                // Progressive edge: a short fade below the bar so content dissolves under it.
                LinearGradient(colors: [Theme.surfaceStroke.opacity(0.55), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 10)
                    .offset(y: 10)
                    .allowsHitTesting(false)
            }
    }
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

/// Redacted placeholder mirroring `MatchRow`'s card geometry (two title lines, two big metrics), for
/// the first-ever load before any row exists. A gentle shimmer conveys progress; Reduce Motion holds
/// it steady. Uses the same `.themedCard()` chrome so the skeleton and real rows share a silhouette.
struct SkeletonMatchRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    bar(width: 150, height: 15)
                    bar(width: 90, height: 11)
                }
                Spacer()
                bar(width: 44, height: 22)
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                bar(width: 62, height: 24)
                bar(width: 62, height: 24)
                Spacer()
            }
        }
        .padding(16)
        .themedCard()
        .opacity(reduceMotion ? 0.6 : (shimmer ? 0.85 : 0.45))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { shimmer = true }
        }
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Theme.surfaceElevated)
            .frame(width: width, height: height)
    }
}

/// One list row: date, field name, duration, distance, mini position badge.
struct MatchRow: View {
    let summary: MatchSummary
    /// Year-aware date label, precomputed off the row builder (see MatchListSupport) so the row
    /// never constructs a formatter on appearance.
    let dateLabel: String
    @EnvironmentObject private var store: MatchStore
    @State private var position: (role: PositionRole, side: PositionSide, confidence: Double)?
    @State private var fieldName: String?
    /// Whether a GPS route was recorded — nil until the lazy detail load resolves it.
    @State private var hasRoute: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dateLabel)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    // Unknown field → show nothing (no placeholder); keep format / route badges.
                    HStack(spacing: 6) {
                        if let fieldName {
                            Text(fieldName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                } else {
                    positionBadge
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                metric(MatchFormat.distance(summary.distanceMeters), "Distance", Theme.pace)
                metric(MatchFormat.shortDuration(summary.duration), "Duration", Theme.signal)
                Spacer()
                if score != nil {
                    positionBadge
                }
            }
        }
        .padding(16)
        .themedCard()
        .task { await loadBadge() }
    }

    /// The position pill, shown only when it's honest: hand-reported positions win (they're the
    /// player's own statement — first + "+N"); otherwise a detected estimate appears only at
    /// confidence ≥ 0.5. No positions and no confident estimate → nothing (never a defaulted "CM").
    @ViewBuilder
    private var positionBadge: some View {
        let reported = summary.record?.reportedPositions ?? []
        if !reported.isEmpty {
            ReportedPositionBadge(positions: reported)
        } else if let position, position.confidence >= 0.5 {
            PositionBadge(role: position.role, side: position.side, confidence: position.confidence)
        }
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
        // Fast path: a previously computed badge renders instantly with no HealthKit fetch or
        // analytics compute — the heavy work happens once per match, ever.
        if let badge = store.cachedBadge(for: summary.id) {
            hasRoute = badge.hasRoute
            fieldName = badge.fieldName
            if let role = badge.role, let side = badge.side, let confidence = badge.confidence {
                position = (role, side, confidence)
            }
            return
        }

        let detail = store.detailModel(for: summary)

        #if DEBUG
        // Signpost the (expensive, first-time) analytics load so per-row cost is trivial to profile.
        let signposter = OSSignposter(subsystem: "com.nicemohawk.MatchTracker", category: "matchrow")
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("loadBadge", id: signpostID)
        let start = Date()
        #endif

        await detail.load()

        #if DEBUG
        signposter.endInterval("loadBadge", interval)
        MatchLog.info("MatchRow badge load took \(String(format: "%.0f", Date().timeIntervalSince(start) * 1000)) ms", category: "matchrow")
        #endif

        hasRoute = !detail.track.isEmpty
        var resolvedFieldName: String?
        var resolvedPosition: (role: PositionRole, side: PositionSide, confidence: Double)?
        if let analytics = detail.analytics {
            // Indoor sessions carry only a placeholder position estimate — don't badge one.
            if summary.record?.format != .indoor {
                resolvedPosition = (analytics.position.role, analytics.position.side, analytics.position.confidence)
            }
            resolvedFieldName = analytics.fieldName
        } else if let fieldID = summary.record?.fieldID {
            // Record-only match: resolve the field name directly (no analytics available).
            resolvedFieldName = store.fields.field(id: fieldID)?.name
        }

        position = resolvedPosition
        fieldName = resolvedFieldName

        // Only persist a stable result: analytics computed, or a record-only match with no HK
        // workout that could still sync a route later. Skips caching a transient "no route" for a
        // workout whose analytics failed this time, so it retries on the next appearance.
        if detail.analytics != nil || summary.workout == nil {
            store.storeBadge(
                MatchBadge(role: resolvedPosition?.role, side: resolvedPosition?.side,
                           confidence: resolvedPosition?.confidence, fieldName: resolvedFieldName,
                           hasRoute: !detail.track.isEmpty),
                for: summary.id
            )
        }
    }
}
