// RunsSection.swift
// MatchTracker
//
// A few narratively-interesting runs (longest, fastest sprint, deepest attack, recovery, late
// burst) highlighted one at a time on a field-relative pitch as the user scrolls a carousel —
// instead of ~200 overlapping polylines on a street map that read as noise.

import SwiftUI
import MatchTrackerKit

struct RunsSection: View {
    @ObservedObject var detail: MatchDetailModel
    let analytics: MatchAnalytics

    @EnvironmentObject private var store: MatchStore
    @State private var narrator = RunNarrator()
    @State private var data: RunsData?
    @State private var selectedRunID: RunSegment.ID?
    @State private var scrolledKeyRunID: RunSegment.ID?
    @State private var showAllRuns = false

    private var runs: [RunSegment] { analytics.runs }

    var body: some View {
        VStack(spacing: 16) {
            if runs.isEmpty {
                Text("No runs detected in this match.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                hero
                summaryLine
                carousel
                aiLabelsFootnote
                allRunsDisclosure
            }
        }
        .onAppear(perform: prepare)
        // Rebuild the curated runs + normalized geometry whenever the analytics change — a field
        // corner edit reprojects the whole match (new rectangle, reclipped runs, new intervals), so
        // the cached `data` must not linger from the old geometry. Resets the selection too, since
        // the reclipped runs carry fresh ids.
        .onChange(of: inputKey) { _, _ in rebuildData() }
    }

    /// The analytics inputs `RunsData` is derived from; when any changes, `data` is stale. The
    /// rectangle is the reprojection trigger (corner edits change it); run / interval / event counts
    /// catch events edits that leave the field but reshape intervals and direction labels.
    private struct RunsInputKey: Equatable {
        let rectangle: OrientedRectangle
        let runCount: Int
        let intervalCount: Int
        let eventCount: Int
    }

    private var inputKey: RunsInputKey {
        RunsInputKey(rectangle: analytics.rectangle, runCount: runs.count,
                     intervalCount: analytics.playingIntervals.count, eventCount: detail.events.count)
    }

    // MARK: - Hero pitch

    /// The pitch runs edge-to-edge: cancel MatchDetailView's 16pt content inset on the canvas only,
    /// leaving the caption aligned with the rest of the padded column.
    private var hero: some View {
        VStack(spacing: 8) {
            directionCaption
            RunsPitchView(
                normalizedRuns: data?.normalizedRuns ?? [:],
                runOrder: runs.map(\.id),
                selectedPoints: selectedRunID.flatMap { data?.normalizedRuns[$0] },
                selectedID: selectedRunID,
                selectedTint: tint(for: selectedRunID)
            )
            .aspectRatio(Self.heroAspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Theme.pitchTurfBottom)
            .padding(.horizontal, -Self.containerInset)
            .contentShape(Rectangle())
            // Swiping on the pitch itself steps to the previous/next run — the pitch is the
            // scrub surface, mirroring the carousel (which follows via select()).
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height),
                              abs(value.translation.width) > 40 else { return }
                        step(value.translation.width < 0 ? 1 : -1)
                    }
            )
        }
    }

    /// Advance the selection through the key runs (falling back to all runs when the current
    /// selection isn't a key run), clamped at the ends.
    private func step(_ delta: Int) {
        let keyIDs = data?.scoredRuns.map(\.id) ?? []
        let ids = keyIDs.contains(where: { $0 == selectedRunID }) || selectedRunID == nil
            ? keyIDs
            : runs.map(\.id)
        guard !ids.isEmpty else { return }
        let currentIndex = selectedRunID.flatMap { id in ids.firstIndex(of: id) } ?? -delta
        let nextIndex = min(max(currentIndex + delta, 0), ids.count - 1)
        guard nextIndex != currentIndex, ids.indices.contains(nextIndex) else { return }
        select(ids[nextIndex])
    }

    /// width / height for the hero — a generously tall ~0.68 of the full screen width.
    private static let heroAspect: CGFloat = 1 / 0.68
    /// The horizontal inset MatchDetailView applies to section content (SwiftUI default padding).
    private static let containerInset: CGFloat = 16

    @ViewBuilder
    private var directionCaption: some View {
        if let directions = data?.halfDirections, !directions.isEmpty {
            HStack(spacing: 16) {
                ForEach(directions.indices, id: \.self) { index in
                    let direction = directions[index]
                    HStack(spacing: 5) {
                        if let label = direction.label {
                            Text(label).captionLabel()
                        }
                        Text(direction.attacksPositiveX ? "Attacking →" : "← Attacking")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Summary line

    private var summaryLine: some View {
        let sprints = runs.filter { $0.intensity == .sprint }.count
        let longest = runs.map(\.distanceMeters).max() ?? 0
        return Text("\(runs.count) runs · \(sprints) sprints · \(MatchFormat.distance(longest)) longest")
            .font(.caption).monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Key-run carousel

    @ViewBuilder
    private var carousel: some View {
        if let scoredRuns = data?.scoredRuns, !scoredRuns.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(scoredRuns) { scoredRun in
                        KeyRunCard(
                            run: scoredRun,
                            aiTitle: narrator.title(forRun: scoredRun.id, inMatch: detail.matchIdentifier),
                            minute: minute(for: scoredRun.segment),
                            isSelected: scoredRun.id == selectedRunID
                        )
                        .id(scoredRun.id)
                        .onTapGesture { select(scoredRun.id) }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolledKeyRunID)
            .scrollIndicators(.hidden)
            // Bleed the scroll view to the screen edges; keep the cards' leading edge aligned with
            // the rest of the padded column via a matching content inset.
            .contentMargins(.horizontal, Self.containerInset, for: .scrollContent)
            .padding(.horizontal, -Self.containerInset)
            .onChange(of: scrolledKeyRunID) { _, newValue in
                guard let newValue, newValue != selectedRunID else { return }
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.35)) { selectedRunID = newValue }
            }
        }
    }

    /// True once at least one carousel card is showing an on-device AI title for this match.
    private var hasAILabels: Bool {
        guard let scoredRuns = data?.scoredRuns else { return false }
        return scoredRuns.contains { narrator.title(forRun: $0.id, inMatch: detail.matchIdentifier) != nil }
    }

    /// A quiet attribution shown only while AI labels are on screen.
    @ViewBuilder
    private var aiLabelsFootnote: some View {
        if hasAILabels {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text("Labels by Apple Intelligence")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - All runs

    private var allRunsDisclosure: some View {
        DisclosureGroup(isExpanded: $showAllRuns) {
            VStack(spacing: 0) {
                ForEach(runs) { run in
                    RunRow(run: run, isSelected: run.id == selectedRunID)
                        .contentShape(Rectangle())
                        .onTapGesture { select(run.id) }
                    if run.id != runs.last?.id { Divider() }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("All runs (\(runs.count))").captionLabel()
        }
        .tint(.secondary)
        .padding(14)
        .themedCard(cornerRadius: 16)
    }

    // MARK: - Selection

    private func select(_ id: RunSegment.ID) {
        Haptics.selection()
        withAnimation(.easeInOut(duration: 0.35)) { selectedRunID = id }
        if data?.scoredRuns.contains(where: { $0.id == id }) == true {
            scrolledKeyRunID = id
        }
    }

    private func tint(for runID: RunSegment.ID?) -> Color {
        guard let runID else { return Theme.turf }
        if let scoredRun = data?.scoredRuns.first(where: { $0.id == runID }) {
            return scoredRun.category?.tint ?? Theme.turf
        }
        if let run = runs.first(where: { $0.id == runID }) {
            return run.intensity.color
        }
        return Theme.turf
    }

    private func minute(for segment: RunSegment) -> Int {
        max(0, Int(segment.interval.start.timeIntervalSince(detail.matchStart) / 60))
    }

    /// Compute the curated key runs + normalized pitch geometry once per appearance, defaulting the
    /// selection/carousel to the first key run. Re-appearing with data already built only re-warms
    /// the labels (selection is preserved); a reprojection routes through `rebuildData()` instead.
    private func prepare() {
        if data == nil {
            rebuildData()
        } else {
            if selectedRunID == nil, let first = data?.scoredRuns.first?.id {
                selectedRunID = first
                scrolledKeyRunID = first
            }
            requestLabels()
        }
    }

    /// Rebuild `data` from the current analytics and reset the selection to the first key run — the
    /// reclipped runs after a reprojection carry new ids, so the prior selection can't be trusted.
    private func rebuildData() {
        let prepared = RunsData.build(
            runs: runs, track: detail.track, projector: analytics.projector,
            events: detail.events, playingIntervals: analytics.playingIntervals,
            matchStart: detail.matchStart, matchEnd: detail.matchEnd,
            baselines: store.runBaselines(excluding: detail.matchIdentifier)
        )
        data = prepared
        let first = prepared.scoredRuns.first?.id
        selectedRunID = first
        scrolledKeyRunID = first
        requestLabels()
    }

    /// Warm the on-device model and kick off labeling for this match's curated runs. Idempotent —
    /// `RunNarrator` caches per match id, so re-appearing or scrubbing never re-runs the model.
    private func requestLabels() {
        narrator.prewarm()
        guard let scoredRuns = data?.scoredRuns, !scoredRuns.isEmpty else { return }

        let features = scoredRuns.enumerated().map { index, scoredRun in
            RunFeature(
                id: scoredRun.id,
                index: index,
                minute: minute(for: scoredRun.segment),
                distanceMeters: scoredRun.segment.distanceMeters,
                peakSpeedKmh: scoredRun.segment.peakSpeed * 3.6,
                direction: data?.directionLabels[scoredRun.id] ?? "",
                reasons: scoredRun.reasons,
                nearbyEventKinds: nearbyEventKinds(for: scoredRun.segment)
            )
        }
        let context = narrationContext()
        let matchID = detail.matchIdentifier
        Task { await narrator.generateLabels(matchID: matchID, features: features, context: context) }
    }

    /// Meaningful match events within ±30 s of a run, as raw kind names for the model prompt.
    private func nearbyEventKinds(for segment: RunSegment) -> [String] {
        let window = DateInterval(start: segment.interval.start.addingTimeInterval(-30),
                                  end: segment.interval.end.addingTimeInterval(30))
        let kinds: Set<MatchEventKind> = [.goalForUs, .goalAgainstUs, .goalMine,
                                          .assist, .flag, .yellowCard, .redCard]
        return detail.events
            .filter { kinds.contains($0.kind) && window.contains($0.date) }
            .map { $0.kind.rawValue }
    }

    /// Final score (us–them) and goal minutes, framing the runs for the model.
    private func narrationContext() -> MatchNarrationContext {
        let us = detail.events.filter { $0.kind == .goalForUs || $0.kind == .goalMine }.count
        let them = detail.events.filter { $0.kind == .goalAgainstUs }.count
        let goalKinds: Set<MatchEventKind> = [.goalForUs, .goalAgainstUs, .goalMine]
        let goalMinutes = detail.events
            .filter { goalKinds.contains($0.kind) }
            .map { minute(for: $0.date) }
            .sorted()
        return MatchNarrationContext(finalScore: "\(us)-\(them)", goalMinutes: goalMinutes)
    }

    private func minute(for date: Date) -> Int {
        max(0, Int(date.timeIntervalSince(detail.matchStart) / 60))
    }
}

// MARK: - Prepared data

/// Everything the section renders that is derived from the (immutable) analytics + track: the
/// curated key runs, each run's normalized pitch polyline, and per-half attack direction.
struct RunsData {
    var scoredRuns: [ScoredRun]
    var normalizedRuns: [RunSegment.ID: [CGPoint]]
    var halfDirections: [HalfDirection]
    /// Per-run attacking-relative direction label ("toward attacking goal" / "toward own goal" /
    /// "lateral"), for grounding the AI prompt. Empty when the attack direction is unknown.
    var directionLabels: [RunSegment.ID: String]

    struct HalfDirection: Equatable {
        var label: String?
        var attacksPositiveX: Bool
    }

    static func build(runs: [RunSegment], track: [TrackPoint], projector: FieldProjector?,
                      events: [MatchEvent], playingIntervals: [DateInterval],
                      matchStart: Date, matchEnd: Date, baselines: RunBaselines?) -> RunsData {
        let scoredRuns = KeyRunSelector.scoredSelection(
            runs: runs, track: track, projector: projector,
            events: events, matchStart: matchStart, matchEnd: matchEnd,
            baselines: baselines, limit: 6
        )

        // Index-aligned normalized track (x = long axis, y = short axis), with a bounding-box
        // fallback so something sensible renders even without a resolved field projector.
        let normalizedTrack = normalize(track: track, projector: projector)

        var normalizedRuns: [RunSegment.ID: [CGPoint]] = [:]
        for run in runs {
            let lower = max(0, run.pointRange.lowerBound)
            let upper = min(normalizedTrack.count, run.pointRange.upperBound)
            guard lower < upper else { continue }
            // Clamp every normalized point into the unit pitch box: the projector tolerates a slop
            // band outside the touchline (normalized values just past [0,1]), but a rendered trace
            // must never draw beyond the pitch rect. Clamping here covers the hero ghost traces AND
            // the bright selected-run highlight, which both read from `normalizedRuns`.
            let points = normalizedTrack[lower..<upper].compactMap { $0 }.map(clampToPitch)
            if points.count > 1 { normalizedRuns[run.id] = points }
        }

        let directions = attackDirections(
            runs: runs, normalizedRuns: normalizedRuns, projector: projector,
            events: events, playingIntervals: playingIntervals,
            matchStart: matchStart, matchEnd: matchEnd
        )
        let directionLabels = runDirectionLabels(
            runs: runs, normalizedRuns: normalizedRuns, halfDirections: directions,
            events: events, playingIntervals: playingIntervals,
            matchStart: matchStart, matchEnd: matchEnd
        )

        return RunsData(scoredRuns: scoredRuns, normalizedRuns: normalizedRuns,
                        halfDirections: directions, directionLabels: directionLabels)
    }

    /// Per-run attack-relative direction, derived from each run's normalized long-axis travel and
    /// its period's attacking direction (index-aligned with `halfDirections`). Empty when the
    /// attack direction couldn't be resolved (no projector), so the AI prompt simply omits it.
    private static func runDirectionLabels(
        runs: [RunSegment], normalizedRuns: [RunSegment.ID: [CGPoint]], halfDirections: [HalfDirection],
        events: [MatchEvent], playingIntervals: [DateInterval], matchStart: Date, matchEnd: Date
    ) -> [RunSegment.ID: String] {
        let periods = periodsForDirection(
            events: events, intervals: playingIntervals, matchStart: matchStart, matchEnd: matchEnd
        )
        guard !halfDirections.isEmpty, periods.count == halfDirections.count else { return [:] }

        var result: [RunSegment.ID: String] = [:]
        for run in runs {
            guard let points = normalizedRuns[run.id], let first = points.first, let last = points.last else { continue }
            let dx = Double(last.x - first.x)
            guard abs(dx) > 0.03 else { result[run.id] = "lateral"; continue }
            let periodIndex = periods.firstIndex { $0.contains(run.interval.start) } ?? 0
            let towardAttack = (dx > 0) == halfDirections[periodIndex].attacksPositiveX
            result[run.id] = towardAttack ? "toward attacking goal" : "toward own goal"
        }
        return result
    }

    /// Clamp a normalized pitch point into the unit box so a rendered polyline never leaves the
    /// pitch rectangle (the projector allows a metric slop band that pushes points just past [0,1]).
    private static func clampToPitch(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }

    /// Normalized [0,1] pitch coordinates for every track point (nil where a point can't project).
    private static func normalize(track: [TrackPoint], projector: FieldProjector?) -> [CGPoint?] {
        if let projector {
            let mapped = track.map { projector.normalizedPoint(for: $0.coordinate) }
            if mapped.contains(where: { $0 != nil }) { return mapped }
        }
        return boundingBoxNormalized(track)
    }

    /// Axis-aligned lat/lon bounding-box normalization (north up). Ignores field rotation, but
    /// gives a legible trace when no projector is available.
    private static func boundingBoxNormalized(_ track: [TrackPoint]) -> [CGPoint?] {
        let coords = track.map(\.coordinate)
        guard let minLat = coords.map(\.latitude).min(),
              let maxLat = coords.map(\.latitude).max(),
              let minLon = coords.map(\.longitude).min(),
              let maxLon = coords.map(\.longitude).max() else {
            return track.map { _ in nil }
        }
        let spanLat = max(maxLat - minLat, 1e-9)
        let spanLon = max(maxLon - minLon, 1e-9)
        return coords.map { coordinate in
            CGPoint(x: (coordinate.longitude - minLon) / spanLon,
                    y: (maxLat - coordinate.latitude) / spanLat)
        }
    }

    /// Attacking direction per half, mirroring `KeyRunSelector`: periods from period events, else
    /// two halves split at the on-pitch midpoint; direction from the sprint-run x-bias.
    private static func attackDirections(
        runs: [RunSegment], normalizedRuns: [RunSegment.ID: [CGPoint]], projector: FieldProjector?,
        events: [MatchEvent], playingIntervals: [DateInterval], matchStart: Date, matchEnd: Date
    ) -> [HalfDirection] {
        guard projector != nil, !normalizedRuns.isEmpty, matchEnd > matchStart else { return [] }

        let periods = periodsForDirection(
            events: events, intervals: playingIntervals, matchStart: matchStart, matchEnd: matchEnd
        )
        guard !periods.isEmpty else { return [] }

        func travel(_ run: RunSegment) -> Double? {
            guard let points = normalizedRuns[run.id], let first = points.first, let last = points.last else { return nil }
            return Double(last.x - first.x)
        }

        let showLabels = periods.count > 1
        return periods.enumerated().map { index, period in
            let inPeriod = runs.filter { period.contains($0.interval.start) }
            let sprintBias = inPeriod.filter { $0.intensity == .sprint }.compactMap(travel).reduce(0, +)
            let bias = sprintBias != 0 ? sprintBias : inPeriod.compactMap(travel).reduce(0, +)
            let label = showLabels ? ordinal(index + 1) : nil
            return HalfDirection(label: label, attacksPositiveX: bias >= 0)
        }
    }

    private static func periodsForDirection(events: [MatchEvent], intervals: [DateInterval],
                                            matchStart: Date, matchEnd: Date) -> [DateInterval] {
        let periodEvents = events
            .filter { $0.kind == .periodStart || $0.kind == .periodEnd }
            .sorted { $0.date < $1.date }
        var periods: [DateInterval] = []
        var openStart: Date?
        for event in periodEvents {
            if event.kind == .periodStart {
                openStart = event.date
            } else if let start = openStart, event.date > start {
                periods.append(DateInterval(start: start, end: event.date))
                openStart = nil
            }
        }
        if let start = openStart, matchEnd > start {
            periods.append(DateInterval(start: start, end: matchEnd))
        }
        if !periods.isEmpty { return periods }

        let total = intervals.reduce(0) { $0 + $1.duration }
        let midpoint: Date
        if total > 0 {
            let target = total / 2
            var accumulated = 0.0
            var found = matchEnd
            for interval in intervals.sorted(by: { $0.start < $1.start }) {
                if accumulated + interval.duration >= target {
                    found = interval.start.addingTimeInterval(target - accumulated)
                    break
                }
                accumulated += interval.duration
            }
            midpoint = found
        } else {
            midpoint = matchStart.addingTimeInterval(matchEnd.timeIntervalSince(matchStart) / 2)
        }
        return [DateInterval(start: matchStart, end: midpoint),
                DateInterval(start: midpoint, end: matchEnd)]
    }

    private static func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }
}

// MARK: - Key-run card

struct KeyRunCard: View {
    let run: ScoredRun
    /// On-device AI title, when generated; nil until it arrives (or on devices without it).
    let aiTitle: String?
    let minute: Int
    let isSelected: Bool

    /// Category tint when the run is a category winner, else the app's turf accent.
    private var tint: Color { run.category?.tint ?? Theme.turf }

    /// Headline: the AI label when present, otherwise the top deterministic reason (fallback chain).
    private var title: String {
        aiTitle ?? run.reasons.first ?? run.category?.label ?? run.segment.intensity.label
    }

    /// When the AI title is showing, the top reason becomes the grounding subtitle. The line is
    /// always reserved (rendered even when empty) so cards never jump as labels stream in.
    private var subtitle: String? {
        aiTitle != nil ? run.reasons.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.category?.label ?? "Run").captionLabel().foregroundStyle(tint)
                Spacer(minLength: 8)
                Text("\(minute)'").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                Text(subtitle ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(MatchFormat.distance(run.segment.distanceMeters))
                .statNumeral()
                .foregroundStyle(.primary)
            HStack(spacing: 16) {
                metric(MatchFormat.speed(run.segment.peakSpeed), "peak")
                metric(MatchFormat.duration(run.segment.interval.duration), "time")
            }
        }
        .padding(14)
        .frame(width: 232, alignment: .leading)
        .themedCard()
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isSelected ? tint : .clear, lineWidth: 1.5)
        )
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
            Text(label).captionLabel()
        }
    }
}

extension KeyRunCategory {
    /// Category tint per the design brief (mapped onto the Theme accent set).
    var tint: Color {
        switch self {
        case .longest: return Theme.pace
        case .fastestSprint: return Theme.heart
        case .deepestAttack: return Theme.sprint
        case .longestRecovery: return Theme.signal
        case .lateBurst: return Theme.goal
        }
    }

    var label: String {
        switch self {
        case .longest: return "Longest Run"
        case .fastestSprint: return "Fastest Sprint"
        case .deepestAttack: return "Deepest Attack"
        case .longestRecovery: return "Recovery Run"
        case .lateBurst: return "Late Burst"
        }
    }
}

// MARK: - Compact run row (all-runs list)

struct RunRow: View {
    let run: RunSegment
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(run.intensity.color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.intensity.label).font(.subheadline.weight(.semibold))
                Text(run.interval.start, format: .dateTime.hour().minute().second())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(MatchFormat.distance(run.distanceMeters)).font(.subheadline).monospacedDigit()
                Text("\(MatchFormat.speed(run.peakSpeed)) peak · \(MatchFormat.duration(run.interval.duration))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? run.intensity.color.opacity(0.12) : .clear)
    }
}

// MARK: - Field-relative pitch canvas

/// Every run drawn as a faint ghost trace over the pitch; the selected run painted bright with a
/// gradient stroke, a start dot and an arrowhead, cross-fading as the selection changes.
struct RunsPitchView: View {
    let normalizedRuns: [RunSegment.ID: [CGPoint]]
    let runOrder: [RunSegment.ID]
    let selectedPoints: [CGPoint]?
    let selectedID: RunSegment.ID?
    let selectedTint: Color

    var body: some View {
        Canvas { context, size in
            let rect = SoccerPitch.fittedRect(in: size, padding: 8)
            SoccerPitch.fillTurf(&context, rect: rect)

            for id in runOrder {
                guard let points = normalizedRuns[id], points.count > 1 else { continue }
                var path = Path()
                path.addLines(points.map { mapped($0, in: rect) })
                context.stroke(path, with: .color(.white.opacity(0.07)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }

            var markings = context
            SoccerPitch.draw(in: &markings, rect: rect)
        }
        .overlay {
            if let selectedPoints, selectedPoints.count > 1 {
                RunHighlight(points: selectedPoints, tint: selectedTint)
                    .id(selectedID)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: selectedID)
    }

    private func mapped(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }
}

/// The bright selected-run overlay: gradient-stroked polyline + glow, a start dot and an arrowhead.
private struct RunHighlight: View {
    let points: [CGPoint]     // normalized [0,1]
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let rect = SoccerPitch.fittedRect(in: geometry.size, padding: 8)
            let mapped = points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            ZStack {
                RunLine(points: mapped)
                    .stroke(
                        LinearGradient(colors: [tint.opacity(0.45), tint],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: .black.opacity(0.30), radius: 2, x: 0, y: 1)
                RunMarkers(points: mapped)
                    .fill(tint)
                    .shadow(color: .black.opacity(0.30), radius: 1.5, x: 0, y: 1)
            }
        }
    }
}

private struct RunLine: Shape {
    let points: [CGPoint]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        path.addLines(points)
        return path
    }
}

private struct RunMarkers: Shape {
    let points: [CGPoint]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1, let first = points.first, let last = points.last else { return path }

        // Start dot.
        path.addEllipse(in: CGRect(x: first.x - 3, y: first.y - 3, width: 6, height: 6))

        // Arrowhead at the finish, pointing along the final segment.
        let previous = points[points.count - 2]
        let dx = last.x - previous.x, dy = last.y - previous.y
        let length = max(hypot(dx, dy), 0.0001)
        let ux = dx / length, uy = dy / length
        let size: CGFloat = 9
        let base = CGPoint(x: last.x - ux * size, y: last.y - uy * size)
        let perpX = -uy, perpY = ux
        let left = CGPoint(x: base.x + perpX * size * 0.55, y: base.y + perpY * size * 0.55)
        let right = CGPoint(x: base.x - perpX * size * 0.55, y: base.y - perpY * size * 0.55)
        path.move(to: last)
        path.addLine(to: left)
        path.addLine(to: right)
        path.closeSubpath()
        return path
    }
}
