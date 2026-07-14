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
}

/// Loads a match's GPS track + heart rate and derives cached analytics via MatchTrackerKit.
/// Field projector resolution order: record.fieldID → bestMatch(track) → inferFieldRectangle.
@MainActor
final class MatchDetailModel: ObservableObject {
    let workout: HKWorkout?
    @Published private(set) var record: MatchRecord?
    @Published private(set) var track: [TrackPoint] = []
    @Published private(set) var analytics: MatchAnalytics?
    @Published private(set) var heartRate: (average: Double, maximum: Double)?
    @Published private(set) var heartRateSeries: [(date: Date, bpm: Double)] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    private let healthKit: HealthKitService
    private let fields: FieldsModel
    private var hasLoaded = false
    private var didReconcileSubs = false

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

        // Record-only match: no HKWorkout, so no track/heart-rate/analytics to fetch. The
        // events timeline still works and upload proceeds with empty coordinates.
        guard let workout else {
            loadFailed = false
            return
        }

        do {
            let points = try await healthKit.fetchTrack(for: workout)
            track = points
            heartRate = try? await healthKit.fetchHeartRate(from: matchStart, to: matchEnd)
            heartRateSeries = (try? await healthKit.fetchHeartRateSeries(from: matchStart, to: matchEnd)) ?? []
            analytics = computeAnalytics(track: points)
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

    /// Recompute after an events edit (playing intervals / position may change). Indoor sessions
    /// have no track but still recompute so a substitution edit reshapes the HR-based workrate.
    func updateRecord(_ record: MatchRecord) {
        self.record = record
        if !track.isEmpty || matchFormat == .indoor {
            analytics = computeAnalytics(track: track)
        }
    }

    // MARK: - Analytics pipeline

    /// A degenerate field used only to satisfy `MatchAnalytics`'s projector-dependent fields for an
    /// indoor session that has no route. Those pieces (heatmap/runs/position) are never rendered for
    /// an indoor match — its detail view reduces to Workrate / Events / Video.
    private static let indoorPlaceholderRectangle = OrientedRectangle(
        center: Coordinate2D(latitude: 0, longitude: 0),
        lengthMeters: 40, widthMeters: 20, headingDegrees: 0, corners: []
    )

    private func computeAnalytics(track: [TrackPoint]) -> MatchAnalytics? {
        let intervals = SubstitutionTracker.playingIntervals(
            events: events, matchStart: matchStart, matchEnd: matchEnd
        )

        // No route to place onto. An indoor session still scores from heart rate alone, so its
        // analytics (and thus the workrate/events views) exist even with an empty track; the
        // projector-dependent pieces stay empty. Any other format with no field is un-analyzable.
        guard let resolved = resolveField(track: track) else {
            guard matchFormat == .indoor else { return nil }
            let context = MatchContext(format: .indoor)
            var workrate = WorkrateAnalyzer.analyze(
                track: track, runs: [], playingIntervals: intervals,
                heartRate: heartRateSamples, context: context
            )
            if let heartRate { workrate.averageHeartRate = heartRate.average }
            return MatchAnalytics(
                rectangle: Self.indoorPlaceholderRectangle,
                projector: FieldProjector(rectangle: Self.indoorPlaceholderRectangle),
                fieldName: nil,
                fieldSource: nil,
                playingIntervals: intervals,
                heatmap: HeatmapGrid(columns: 30, rows: 20, cells: []),
                runs: [],
                workrate: workrate,
                position: PositionEstimate(role: .midfielder, side: .center, confidence: 0,
                                           meanPoint: CGPoint(x: 0.5, y: 0.5), periodMeanPoints: [])
            )
        }

        let projector = FieldProjector(rectangle: resolved.rectangle)
        let context = MatchContext(format: matchFormat,
                                   fieldLengthMeters: resolved.rectangle.lengthMeters)
        let heatmap = HeatmapGrid.compute(
            points: track, projector: projector, columns: 30, rows: 20, playingIntervals: intervals
        )
        let runs = RunDetector.detectRuns(in: track, configuration: .scaled(for: context))
        var workrate = WorkrateAnalyzer.analyze(
            track: track, runs: runs, playingIntervals: intervals,
            heartRate: heartRateSamples, context: context
        )
        if let heartRate { workrate.averageHeartRate = heartRate.average }
        let position = PositionAnalyzer.estimate(
            points: track, projector: projector, events: events, playingIntervals: intervals
        )
        return MatchAnalytics(
            rectangle: resolved.rectangle,
            projector: projector,
            fieldName: resolved.name,
            fieldSource: resolved.source,
            playingIntervals: intervals,
            heatmap: heatmap,
            runs: runs,
            workrate: workrate,
            position: position
        )
    }

    private struct ResolvedField {
        var rectangle: OrientedRectangle
        var name: String?
        var source: FieldSource?
    }

    private func resolveField(track: [TrackPoint]) -> ResolvedField? {
        // 1. Explicit field id on the record.
        if let fieldID = record?.fieldID, let field = fields.field(id: fieldID) {
            return ResolvedField(rectangle: field.rectangle, name: field.name, source: field.source)
        }
        // 2. Best geometric match against saved fields.
        let coordinates = track.map(\.coordinate)
        if let matched = fields.store.bestMatch(for: coordinates) {
            return ResolvedField(rectangle: matched.rectangle, name: matched.name, source: matched.source)
        }
        // 3. Infer a rectangle from the track itself.
        if let inferred = FieldGeometry.inferFieldRectangle(from: track) {
            return ResolvedField(rectangle: inferred, name: nil, source: .inferred)
        }
        // 4. Last resort: naive bounding rectangle so the views still render.
        if let naive = FieldGeometry.fitOrientedRectangle(to: coordinates) {
            return ResolvedField(rectangle: naive, name: nil, source: nil)
        }
        return nil
    }
}
