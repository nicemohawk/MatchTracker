// MatchDetailModel.swift
// MatchTracker

import Foundation
import HealthKit
import CoreGraphics
import MatchTrackerKit

/// All analytics for one match, computed once from the track + resolved field projector.
struct MatchAnalytics {
    var rectangle: OrientedRectangle
    var projector: FieldProjector
    var fieldName: String?
    var fieldSource: FieldSource?
    var playingIntervals: [DateInterval]
    var heatmap: HeatmapGrid
    var runs: [RunSegment]
    var workrate: WorkrateReport
    var position: PositionEstimate
    /// Industry-standard soccer load metrics (sprint distance, HSR, accel/decel counts, etc.),
    /// computed only for GPS matches. Nil for indoor / HR-only sessions, which have no route.
    var loadMetrics: SoccerLoadMetrics?
}

/// Loads a match's GPS track + heart rate and derives cached analytics via MatchTrackerKit.
/// Field projector resolution order: record.fieldID → bestMatch(track) → FieldFitter dense-core fit.
@MainActor
final class MatchDetailModel: ObservableObject {
    let workout: HKWorkout?
    @Published private(set) var record: MatchRecord?
    @Published private(set) var track: [TrackPoint] = []
    @Published private(set) var analytics: MatchAnalytics?
    /// Monotonic version bumped every time `analytics` is republished — a cheap identity for views
    /// that cache values derived from the analysis (e.g. the Compare cohort) and need to know when
    /// to rebuild them without diffing the analytics themselves.
    @Published private(set) var analyticsRevision = 0
    @Published private(set) var heartRate: (average: Double, maximum: Double)?
    @Published private(set) var heartRateSeries: [(date: Date, bpm: Double)] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    private let healthKit: HealthKitService
    private let fields: FieldsModel
    private var hasLoaded = false
    private var didReconcileSubs = false
    /// Coalescing for off-main recomputes: while a pass is in flight, further requests set the flag
    /// so exactly ONE follow-up pass runs at the end instead of queueing one per request.
    private var analyticsTask: Task<Void, Never>?
    private var needsReanalyze = false

    /// Persist an updated record through the app's store (set by `MatchStore`). When wired, this
    /// writes the record to disk and refreshes the cached summary + analytics.
    var persist: ((MatchRecord) -> Void)?

    init(summary: MatchSummary, healthKit: HealthKitService, fields: FieldsModel) {
        self.workout = summary.workout
        self.record = summary.record
        self.healthKit = healthKit
        self.fields = fields
    }

    var matchStart: Date { record?.startDate ?? workout?.startDate ?? .distantPast }
    var matchEnd: Date { record?.endDate ?? workout?.endDate ?? matchStart }
    var events: [MatchEvent] { record?.events ?? [] }

    /// The match's format; a record written before formats existed (or none at all) is `.match`.
    var matchFormat: MatchTrackerKit.MatchFormat { record?.format ?? .match }

    /// The already-fetched heart-rate series mapped into the Kit's format-agnostic samples so the
    /// analyzer can score effort from heart rate (the only signal indoor sessions can trust).
    private var heartRateSamples: [HeartRateSample] {
        heartRateSeries.map { HeartRateSample(date: $0.date, bpm: $0.bpm) }
    }

    /// Stable identifier for persisting edits, whether backed by a workout or a record.
    var matchIdentifier: UUID { workout?.uuid ?? record?.id ?? UUID() }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true
        defer { isLoading = false }

        // Record-only match: no HKWorkout, so no HealthKit route to fetch. If the watch attached
        // the redundant track to the record (the workout save failed), run the full pipeline off
        // it; otherwise the events timeline still works and upload proceeds with empty coordinates.
        guard let workout else {
            loadFailed = false
            guard let recordTrack = record?.track, !recordTrack.isEmpty else { return }
            MatchLog.info("match \(matchIdentifier): record-only, using record track fallback",
                          category: "matchdetail")
            track = recordTrack
            let start = matchStart, end = matchEnd
            async let fetchedHeartRate = healthKit.fetchHeartRate(from: start, to: end)
            async let fetchedSeries = healthKit.fetchHeartRateSeries(from: start, to: end)
            heartRate = try? await fetchedHeartRate
            heartRateSeries = (try? await fetchedSeries) ?? []
            publishAnalytics(await computeAnalyticsOffMain())
            loadFailed = analytics == nil && !recordTrack.isEmpty
            reconcileAutomaticSubs(track: recordTrack)
            return
        }

        do {
            // The route fetch and the two heart-rate queries are independent of each other, so the
            // three HealthKit round-trips run concurrently. Error semantics are unchanged: a failed
            // track fetch fails the load (unless the record carries the redundant track); the
            // heart-rate fetches degrade to nil/empty.
            let start = matchStart, end = matchEnd
            async let fetchedTrack = healthKit.fetchTrack(for: workout)
            async let fetchedHeartRate = healthKit.fetchHeartRate(from: start, to: end)
            async let fetchedSeries = healthKit.fetchHeartRateSeries(from: start, to: end)

            // The HealthKit route is primary; the record's redundant track rescues a workout whose
            // route fetch returned nothing or threw — e.g. the route save failed on the watch. A
            // fetch failure with no fallback still fails the load, exactly as before.
            var points: [TrackPoint]
            do {
                points = try await fetchedTrack
            } catch {
                guard record?.track?.isEmpty == false else { throw error }
                points = []
            }
            if points.isEmpty, let recordTrack = record?.track, !recordTrack.isEmpty {
                MatchLog.info("match \(matchIdentifier): HealthKit route missing, using record track fallback",
                              category: "matchdetail")
                points = recordTrack
            }
            track = points
            heartRate = try? await fetchedHeartRate
            heartRateSeries = (try? await fetchedSeries) ?? []
            publishAnalytics(await computeAnalyticsOffMain())
            loadFailed = analytics == nil && !points.isEmpty
            reconcileAutomaticSubs(track: points)
        } catch {
            loadFailed = true
        }
    }

    /// Post-match reconciliation: for a match with a resolved field, run the offline detectors
    /// once — automatic subs when no sub events exist, and period boundaries when no period
    /// events exist (the watch normally detects periods at endMatch, but matches recorded
    /// before that shipped, demo matches, and edge-case failures land here). Guarded to run a
    /// single time per load so re-computation on edits can never loop back into detection.
    private func reconcileAutomaticSubs(track: [TrackPoint]) {
        guard !didReconcileSubs else { return }
        didReconcileSubs = true

        guard let record, let analytics, !track.isEmpty else { return }
        var detected: [MatchEvent] = []

        let hasSubEvents = record.events.contains { $0.kind == .subIn || $0.kind == .subOut }
        if !hasSubEvents {
            detected += AutoSubDetector.detectEvents(
                track: track, projector: analytics.projector,
                existingEvents: record.events, configuration: AutoSubDetectorConfiguration()
            )
        }

        // PeriodDetector returns [] on its own when period events already exist.
        detected += PeriodDetector.detectPeriods(
            track: track, events: record.events + detected,
            projector: analytics.projector, configuration: PeriodDetectorConfiguration()
        )

        guard !detected.isEmpty else { return }

        var merged = record
        merged.events.append(contentsOf: detected)
        merged.events.sort { $0.date < $1.date }
        if let persist {
            persist(merged)          // writes to disk and recomputes analytics via the store
        } else {
            updateRecord(merged)     // standalone fallback: refresh locally
        }
    }

    /// Recompute after an events edit (playing intervals / position may change). Route-less sessions
    /// have no track but still recompute when they can score from heart rate (indoor, or any import
    /// with HR samples) so a substitution edit reshapes the HR-based workrate.
    func updateRecord(_ record: MatchRecord) {
        self.record = record
        if !track.isEmpty || matchFormat == .indoor || !heartRateSamples.isEmpty {
            scheduleAnalyticsRecompute()
        }
    }

    // MARK: - Field-edit recompute

    /// Rebuild this match's analytics after its resolved field's geometry changed (a corner edit
    /// from this screen or the Fields tab). The field rectangle is the projection basis for the
    /// heatmap / position / thirds / runs, so a boundary edit invalidates all of it. Reuses the
    /// already-fetched track + heart rate (no HealthKit round-trip) and recomputes from the current
    /// field resolution. A no-op before the first `load()`, where `load()` will pick up the new
    /// geometry itself; safe to call repeatedly. Non-blocking: the pipeline runs off the main actor
    /// and the refreshed analytics publish back here when done.
    func reanalyze() {
        guard hasLoaded else { return }
        scheduleAnalyticsRecompute()
    }

    /// Recompute analytics without blocking the main actor, coalescing bursts (e.g. a field edit
    /// fanning out reanalyzes) into at most one in-flight pass plus one follow-up.
    private func scheduleAnalyticsRecompute() {
        needsReanalyze = true
        guard analyticsTask == nil else { return }
        analyticsTask = Task { [weak self] in
            while let self, self.needsReanalyze {
                self.needsReanalyze = false
                let result = await self.computeAnalyticsOffMain()
                self.publishAnalytics(result)
            }
            self?.analyticsTask = nil
        }
    }

    /// Snapshot the pipeline's inputs on the main actor, run the pure computation on a background
    /// task, and return the result here for publishing.
    private func computeAnalyticsOffMain() async -> MatchAnalytics? {
        let inputs = analyticsInputs()
        return await Task.detached(priority: .userInitiated) {
            Self.computeAnalytics(inputs: inputs)
        }.value
    }

    private func publishAnalytics(_ result: MatchAnalytics?) {
        analytics = result
        analyticsRevision &+= 1
    }

    /// Whether this match has an on-pitch field whose corners can be adjusted — a real GPS match with
    /// a resolved rectangle, not an indoor / HR-only placeholder (whose rectangle carries no corners).
    var canAdjustField: Bool {
        guard let analytics else { return false }
        return analytics.rectangle.corners.count == 4 && !track.isEmpty
    }

    /// A corner correction from the match screen edits this field. `isDraft` distinguishes the two
    /// cases the caller must handle on save.
    struct AdjustableField {
        /// The `FieldModel` to hand to `CornerEditorView`.
        var field: FieldModel
        /// True when `field` is a fresh draft synthesized from an inferred / naive projection (no
        /// saved field backed this match). The caller binds it to the record on save via `bindField`.
        var isDraft: Bool
    }

    /// The field a corner correction should edit. When the match resolves to a saved field (explicit
    /// id, else geometric best-match), that exact field is returned so the edit re-fits geometry for
    /// every match that uses it. Otherwise the resolved rectangle (inferred from the track, or a naive
    /// bounding fit) is wrapped in a draft field to edit and persist. Nil when no field is resolved.
    func adjustableField() -> AdjustableField? {
        guard canAdjustField, let analytics else { return nil }
        if let fieldID = record?.fieldID, let field = fields.field(id: fieldID) {
            return AdjustableField(field: field, isDraft: false)
        }
        if let matched = fields.store.bestMatch(for: track.map(\.coordinate)) {
            return AdjustableField(field: matched, isDraft: false)
        }
        let draft = FieldModel(
            id: UUID(),
            name: analytics.fieldName ?? "Match Field",
            createdAt: Date(),
            outline: analytics.rectangle.corners,
            rectangle: analytics.rectangle,
            source: analytics.fieldSource ?? .inferred,
            observationCount: 0
        )
        return AdjustableField(field: draft, isDraft: true)
    }

    /// Pin a freshly-corrected draft field to this match's record so the match always resolves to it.
    /// Only for the draft path (a match that had no saved field before the correction); persisting the
    /// record recomputes analytics through the store, matching the geometry the corner edit produced.
    func bindField(id: UUID) {
        guard var record, record.fieldID != id else { return }
        record.fieldID = id
        if let persist { persist(record) } else { updateRecord(record) }
    }

    // MARK: - Analytics pipeline

    /// Everything the pure pipeline needs, snapshotted on the main actor. All value types (the Kit
    /// analytics types are Sendable), so `computeAnalytics` can run on a background task without
    /// touching the model.
    private struct AnalyticsInputs: Sendable {
        var track: [TrackPoint]
        var events: [MatchEvent]
        var matchStart: Date
        var matchEnd: Date
        var format: MatchTrackerKit.MatchFormat
        var heartRateSamples: [HeartRateSample]
        var heartRate: (average: Double, maximum: Double)?
        var knownField: ResolvedField?
    }

    private func analyticsInputs() -> AnalyticsInputs {
        AnalyticsInputs(
            track: track,
            events: events,
            matchStart: matchStart,
            matchEnd: matchEnd,
            format: matchFormat,
            heartRateSamples: heartRateSamples,
            heartRate: heartRate,
            knownField: knownField()
        )
    }

    /// A degenerate field used only to satisfy `MatchAnalytics`'s projector-dependent fields for an
    /// indoor session that has no route. Those pieces (heatmap/runs/position) are never rendered for
    /// an indoor match — its detail view reduces to Workrate / Events / Video.
    private nonisolated static let indoorPlaceholderRectangle = OrientedRectangle(
        center: Coordinate2D(latitude: 0, longitude: 0),
        lengthMeters: 40, widthMeters: 20, headingDegrees: 0, corners: []
    )

    /// On/off-field slop (meters) for clipping analysis to the pitch: track points, runs, and the
    /// geometry-derived playing intervals all treat a coordinate this far outside the touchline as
    /// still "on field". ~6 m absorbs GPS jitter and players who overrun the line without admitting
    /// warm-up laps, the bench, or the walk to the car.
    private nonisolated static let onFieldMarginMeters = 6.0

    /// The pure pipeline — tens of thousands of GPS points across multiple passes, so it is
    /// `nonisolated` and always invoked from a detached task, never on the main actor.
    private nonisolated static func computeAnalytics(inputs: AnalyticsInputs) -> MatchAnalytics? {
        let track = inputs.track
        // Manual sub events still drive the Events timeline, and stand in as the playing-interval
        // source for route-less sessions (below) where there's no geometry to derive them from.
        let recordedIntervals = SubstitutionTracker.playingIntervals(
            events: inputs.events, matchStart: inputs.matchStart, matchEnd: inputs.matchEnd
        )

        // No route to place onto. Heart rate alone still scores workrate, so any route-less match
        // that has HR samples gets analytics (and thus the workrate/events views) even with an
        // empty track — an indoor session, or a backlog import Apple saved without a route. The
        // projector-dependent pieces (heatmap/runs/position) stay empty; they are never fabricated.
        // Without HR (and not indoor, which always scores HR-only even at HR 0) there is nothing to
        // analyze.
        guard let resolved = resolveField(track: track, knownField: inputs.knownField) else {
            guard inputs.format == .indoor || !inputs.heartRateSamples.isEmpty else { return nil }
            // HR-only path: pass an indoor context so WorkrateAnalyzer weights effort from heart
            // rate alone (its distance scaling is unused with no track) and stamps effort_source
            // "hr". This is the exact call the indoor branch makes — reused for any route-less match.
            let context = MatchContext(format: .indoor)
            var workrate = WorkrateAnalyzer.analyze(
                track: track, runs: [], playingIntervals: recordedIntervals,
                heartRate: inputs.heartRateSamples, context: context
            )
            if let heartRate = inputs.heartRate { workrate.averageHeartRate = heartRate.average }
            return MatchAnalytics(
                rectangle: indoorPlaceholderRectangle,
                projector: FieldProjector(rectangle: indoorPlaceholderRectangle),
                fieldName: nil,
                fieldSource: nil,
                playingIntervals: recordedIntervals,
                heatmap: HeatmapGrid(columns: 30, rows: 20, cells: []),
                runs: [],
                workrate: workrate,
                position: PositionEstimate(role: .midfielder, side: .center, confidence: 0,
                                           meanPoint: CGPoint(x: 0.5, y: 0.5), periodMeanPoints: []),
                loadMetrics: nil   // indoor / HR-only: no route to derive GPS load metrics from
            )
        }

        let projector = FieldProjector(rectangle: resolved.rectangle)
        let context = MatchContext(format: inputs.format,
                                   fieldLengthMeters: resolved.rectangle.lengthMeters)

        // Everything below is projected through THIS field, so re-running it after a corner edit
        // reprojects AND reclips the whole match against the new geometry.

        // Time on pitch is derived from the GEOMETRY for GPS matches: where the player actually was
        // relative to the (possibly just-edited) touchline, not from manual sub events. Those events
        // still show in the Events timeline; they simply don't define workrate/time-on-pitch here.
        // Fall back to the recorded-event intervals only if the deriver yields nothing.
        let derived = PlayIntervalDeriver.playingIntervals(
            track: track, field: resolved.rectangle,
            matchStart: inputs.matchStart, matchEnd: inputs.matchEnd, marginMeters: onFieldMarginMeters
        )
        let intervals = derived.isEmpty ? recordedIntervals : derived

        // Reclip: heatmap and position are placed only from ON-FIELD points, so off-field warm-up
        // laps, the bench, and the walk-off never smear onto the pitch or bias the position dot.
        let onFieldTrack = track.filter {
            projector.isOnField($0.coordinate, marginMeters: onFieldMarginMeters)
        }

        let heatmap = HeatmapGrid.compute(
            points: onFieldTrack, projector: projector, columns: 30, rows: 20, playingIntervals: intervals
        )

        // Runs are detected over the full track (a run can briefly clip the line), then clipped:
        // any run whose majority of points fall off-field is an off-pitch excursion, not play.
        let detectedRuns = RunDetector.detectRuns(in: track, configuration: .scaled(for: context))
        let runs = detectedRuns.filter { isOnFieldRun($0, track: track, projector: projector) }

        var workrate = WorkrateAnalyzer.analyze(
            track: track, runs: runs, playingIntervals: intervals,
            heartRate: inputs.heartRateSamples, context: context
        )
        if let heartRate = inputs.heartRate { workrate.averageHeartRate = heartRate.average }
        let position = PositionAnalyzer.estimate(
            points: onFieldTrack, projector: projector, events: inputs.events, playingIntervals: intervals
        )
        // Industry-standard load metrics from the GPS route + on-pitch intervals — surfaced next
        // to the workrate so our numbers speak the same language as STATSports/Catapult.
        let loadMetrics = SoccerLoadMetrics.compute(track: track, playingIntervals: intervals)
        return MatchAnalytics(
            rectangle: resolved.rectangle,
            projector: projector,
            fieldName: resolved.name,
            fieldSource: resolved.source,
            playingIntervals: intervals,
            heatmap: heatmap,
            runs: runs,
            workrate: workrate,
            position: position,
            loadMetrics: loadMetrics
        )
    }

    /// Whether the majority of a run's track points lie on the field — the clip test that keeps
    /// off-pitch excursions (warm-up jog, walk to the bench) out of the runs set.
    private nonisolated static func isOnFieldRun(_ run: RunSegment, track: [TrackPoint], projector: FieldProjector) -> Bool {
        let lower = max(0, run.pointRange.lowerBound)
        let upper = min(track.count, run.pointRange.upperBound)
        guard lower < upper else { return false }
        let points = track[lower..<upper]
        let onField = points.reduce(0) {
            $0 + (projector.isOnField($1.coordinate, marginMeters: onFieldMarginMeters) ? 1 : 0)
        }
        return onField * 2 >= points.count
    }

    private struct ResolvedField: Sendable {
        var rectangle: OrientedRectangle
        var name: String?
        var source: FieldSource?
    }

    /// Field-resolution steps that need the main-actor models — run at input capture, before the
    /// pipeline hops off the main actor. The track-fitting fallbacks run inside `resolveField`.
    private func knownField() -> ResolvedField? {
        // 1. Explicit field id on the record.
        if let fieldID = record?.fieldID, let field = fields.field(id: fieldID) {
            return ResolvedField(rectangle: field.rectangle, name: field.name, source: field.source)
        }
        // 2. Best geometric match against saved fields.
        if let matched = fields.store.bestMatch(for: track.map(\.coordinate)) {
            return ResolvedField(rectangle: matched.rectangle, name: matched.name, source: matched.source)
        }
        return nil
    }

    private nonisolated static func resolveField(track: [TrackPoint], knownField: ResolvedField?) -> ResolvedField? {
        // 1–2. Explicit field id / best saved-field match, resolved on the main actor at capture.
        if let knownField { return knownField }
        // 3. Fit a rectangle from the track itself — the robust dense-core fit (rejects warm-up
        //    walks / bench stints), NOT a bounding box, so an inferred field lands on the pitch.
        if let fitted = FieldFitter.fitFieldRectangle(track: track) {
            return ResolvedField(rectangle: fitted, name: nil, source: .inferred)
        }
        // 4. Last resort: naive bounding rectangle so the views still render.
        if let naive = FieldGeometry.fitOrientedRectangle(to: track.map(\.coordinate)) {
            return ResolvedField(rectangle: naive, name: nil, source: nil)
        }
        return nil
    }
}
