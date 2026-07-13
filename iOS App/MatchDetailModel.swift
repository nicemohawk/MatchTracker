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

    init(summary: MatchSummary, healthKit: HealthKitService, fields: FieldsModel) {
        self.workout = summary.workout
        self.record = summary.record
        self.healthKit = healthKit
        self.fields = fields
    }

    var matchStart: Date { record?.startDate ?? workout?.startDate ?? .distantPast }
    var matchEnd: Date { record?.endDate ?? workout?.endDate ?? matchStart }
    var events: [MatchEvent] { record?.events ?? [] }

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
        } catch {
            loadFailed = true
        }
    }

    /// Recompute after an events edit (playing intervals / position may change).
    func updateRecord(_ record: MatchRecord) {
        self.record = record
        if !track.isEmpty {
            analytics = computeAnalytics(track: track)
        }
    }

    // MARK: - Analytics pipeline

    private func computeAnalytics(track: [TrackPoint]) -> MatchAnalytics? {
        guard let resolved = resolveField(track: track) else { return nil }
        let projector = FieldProjector(rectangle: resolved.rectangle)
        let intervals = SubstitutionTracker.playingIntervals(
            events: events, matchStart: matchStart, matchEnd: matchEnd
        )
        let heatmap = HeatmapGrid.compute(
            points: track, projector: projector, columns: 30, rows: 20, playingIntervals: intervals
        )
        let runs = RunDetector.detectRuns(in: track, configuration: RunDetectorConfiguration())
        var workrate = WorkrateAnalyzer.analyze(track: track, runs: runs, playingIntervals: intervals)
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
