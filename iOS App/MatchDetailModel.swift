// MatchDetailModel.swift
// MatchTracker

import Foundation
import HealthKit
import MatchTrackerKit

/// Loads a match's GPS track + heart rate and analyzes it with the Kit's `MatchAnalyzer`.
/// Field resolution order: record.fieldID → best saved field → fitted from the track.
@MainActor
final class MatchDetailModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        /// Loaded. A match without GPS is loaded with an empty `track`.
        case loaded
        /// Couldn't be read, in words for the reader. `retry()` tries again.
        case failed(String)
    }

    /// Stable identifier for persisting edits, whether backed by a workout or a record.
    let matchIdentifier: UUID
    @Published private(set) var workout: HKWorkout?
    @Published private(set) var record: MatchRecord?
    @Published private(set) var state: LoadState = .loading
    /// The route between `matchStart` and `matchEnd`.
    @Published private(set) var track: [TrackPoint] = []
    @Published private(set) var analytics: MatchAnalytics?
    /// Monotonic version bumped every time `analytics` is republished — a cheap identity for views
    /// that cache values derived from the analysis (e.g. the Compare cohort) and need to know when
    /// to rebuild them without diffing the analytics themselves.
    @Published private(set) var analyticsRevision = 0
    @Published private(set) var heartRateSeries: [(date: Date, bpm: Double)] = []
    /// Set once the match has been analyzed.
    @Published private(set) var digest: MatchDigest?
    /// Where an untrimmed recording left running should end, if it was.
    @Published private(set) var suggestedTrimEnd: Date?

    private let healthKit: HealthKitService
    private let fields: FieldsModel
    /// Everything HealthKit holds for the whole recording, kept so edits never refetch.
    private var samples: MatchSamples?
    private var loadTask: Task<Void, Never>?
    private var wantsLoad = false
    /// False for a cold-launch row whose workout hasn't come back from HealthKit yet. A match read
    /// without its workout would look like one without GPS.
    private var hasSource: Bool
    /// Coalescing for off-main recomputes: while a pass is in flight, further requests set the flag
    /// so exactly ONE follow-up pass runs at the end instead of queueing one per request.
    private var analyticsTask: Task<Void, Never>?
    private var needsReanalyze = false

    /// Persist an updated record through the app's store (set by `MatchStore`). When wired, this
    /// writes the record to disk and refreshes the cached summary + analytics.
    var persist: ((MatchRecord) -> Void)?
    /// Called with every fresh analysis (set by `MatchStore`, which keeps the digest).
    var onAnalyzed: ((MatchDetailModel) -> Void)?
    /// The sentence for a digest among every other match (set by `MatchStore`).
    var makeHeadline: ((MatchDigest) -> String?)?
    /// Ask HealthKit for the match list again (set by `MatchStore`).
    var refreshMatches: (() async -> Void)?

    init(summary: MatchSummary, healthKit: HealthKitService, fields: FieldsModel) {
        matchIdentifier = summary.id
        workout = summary.workout
        record = summary.record
        hasSource = summary.hasSource
        self.healthKit = healthKit
        self.fields = fields
    }

    /// The whole recording, before any trim.
    var recordedInterval: DateInterval {
        MatchSummary.recordedInterval(workout: workout, record: record)
    }

    /// The match as played: the recording, cut to the trim.
    var playedInterval: DateInterval { record?.played(within: recordedInterval) ?? recordedInterval }

    /// How much of the recording the match was, for totals Health keeps only for the whole.
    var playedShare: Double {
        recordedInterval.duration > 0 ? playedInterval.duration / recordedInterval.duration : 1
    }

    var matchStart: Date { playedInterval.start }
    var matchEnd: Date { playedInterval.end }
    var events: [MatchEvent] { record?.events ?? [] }
    var minutes: MatchMinutes { MatchMinutes(kickoff: matchStart, halftime: analytics?.halftime) }
    /// The minute an event fell in, counted the way football does.
    func minute(of event: MatchEvent) -> Int { minutes.minute(of: event.date) }
    var matchFormat: MatchTrackerKit.MatchFormat { MatchSummary.format(workout: workout, record: record) }

    var isLoading: Bool { state == .loading }
    var heartRate: (average: Double, maximum: Double)? {
        guard let average = analytics?.averageHeartRate, let maximum = analytics?.maximumHeartRate else { return nil }
        return (average, maximum)
    }
    /// The most interesting true thing about this match.
    var headline: String? { digest.flatMap { makeHeadline?($0) } }
    /// Meters covered in each minute of the match. Empty without a route.
    var intensity: [Double] { analytics?.metersPerMinute ?? [] }

    // MARK: - Loading

    func load() async {
        wantsLoad = true
        if samples == nil, loadTask == nil {
            guard hasSource else { return }   // `update` loads it
            loadTask = Task {
                await fetchAndAnalyze()
                loadTask = nil
            }
        }
        await loadTask?.value
    }

    /// Try again after a failure.
    func retry() async {
        state = .loading
        if !hasSource { await refreshMatches?() }
        await load()
    }

    /// The match list couldn't be read, so a match still waiting for its workout won't get it.
    func sourceUnavailable() {
        if wantsLoad, !hasSource { state = .failed(Self.unreadable) }
    }

    private static let unreadable = "This match couldn’t be read from Health."

    /// Take on whatever the store has learned about this match since the model was made.
    func update(from summary: MatchSummary) {
        let gainedSource = !hasSource && summary.hasSource
        hasSource = hasSource || summary.hasSource
        let gainedWorkout = workout == nil && summary.workout != nil
        if gainedWorkout { workout = summary.workout }
        if let record = summary.record,
           record.digestStamp != self.record?.digestStamp || record.notes != self.record?.notes {
            updateRecord(record)
        }
        // A route can reach the phone well after its workout and record.
        let awaitsRoute = state == .loaded && analytics?.hasRoute != true && matchFormat != .indoor
            && (self.record?.track != nil || matchEnd > Date().addingTimeInterval(-7 * 86_400))
        guard wantsLoad, gainedWorkout || gainedSource || awaitsRoute else { return }
        // Whatever was read without the workout is incomplete.
        if analytics?.hasRoute != true, !awaitsRoute { state = .loading }
        Task {
            await loadTask?.value
            samples = nil
            await load()
        }
    }

    private func fetchAndAnalyze() async {
        do {
            samples = try await healthKit.fetchSamples(for: workout, record: record,
                                                       recorded: recordedInterval, played: playedInterval)
        } catch {
            MatchLog.error("match \(matchIdentifier): load failed: \(error.localizedDescription)", category: "matchdetail")
            state = .failed(HealthKitService.isLocked(error)
                ? "Health data is locked. Unlock your iPhone and try again."
                : Self.unreadable)
            return
        }
        await analyze()
        state = .loaded
        redetectEvents()
    }

    /// Replace events an older detector found, once. Needs the route, so it waits for the match to
    /// be opened.
    private func redetectEvents() {
        guard let record, let analytics, analytics.hasRoute,
              (record.detection ?? 0) < MatchRecord.currentDetection else { return }
        let track = track, heartRate = heartRateSeries.map { HeartRateSample(date: $0.date, bpm: $0.bpm) }
        Task {
            let redetected = await Task.detached(priority: .userInitiated) { () -> MatchRecord in
                var record = record
                record.redetectEvents(track: track, projector: analytics.projector, halftime: analytics.halftime, heartRate: heartRate)
                return record
            }.value
            // An edit made meanwhile wins, as does a newer copy from the watch that's on disk and not
            // here yet; detection runs again next time.
            let id = record.id
            let onDisk = await Task.detached { MatchStore.decodeRecord(from: AppGroup.matchRecordURL(for: id)) }.value
            guard onDisk == nil || onDisk?.digestStamp == record.digestStamp else { return }
            guard self.record?.digestStamp == record.digestStamp, self.record?.notes == record.notes else { return }
            save(redetected)
        }
    }

    private func save(_ record: MatchRecord) {
        if let persist { persist(record) } else { updateRecord(record) }
    }

    /// Recompute after an edit (trim, events, positions, direction all reshape the analysis).
    func updateRecord(_ record: MatchRecord) {
        let trimChanged = record.trimmedStart != self.record?.trimmedStart || record.trimmedEnd != self.record?.trimmedEnd
        self.record = record
        guard samples != nil else { return }
        if trimChanged {
            // HealthKit measures distance per interval.
            Task {
                samples?.distanceMeters = await healthKit.fetchDistance(of: workout, recorded: recordedInterval,
                                                                        played: playedInterval)
                scheduleAnalysis()
            }
        } else {
            scheduleAnalysis()
        }
    }

    // MARK: - Field edits

    /// Rebuild this match's analytics after its resolved field's geometry changed (a corner edit
    /// from this screen or the Fields tab). Reuses the already-fetched samples. A no-op before the
    /// first `load()`, which picks up the new geometry itself; safe to call repeatedly.
    func reanalyze() {
        guard samples != nil else { return }
        scheduleAnalysis()
    }

    /// Whether this match has an on-pitch field whose corners can be adjusted — a real GPS match with
    /// a resolved rectangle, not an indoor / HR-only placeholder (whose rectangle carries no corners).
    var canAdjustField: Bool {
        guard let analytics else { return false }
        return analytics.rectangle.corners.count == 4 && !track.isEmpty
    }

    /// A corner correction from the match screen edits this field. `isDraft` distinguishes the two
    /// cases the caller must handle on save.
    /// Identifiable so callers can present it via `sheet(item:)` — the payload arrives atomically
    /// with the presentation, unlike `sheet(isPresented:)` + optional, which can evaluate the
    /// sheet body before the optional commits and present an empty shell.
    struct AdjustableField: Identifiable {
        /// The `FieldModel` to hand to `CornerEditorView`.
        var field: FieldModel
        /// True when `field` is a fresh draft synthesized from an inferred / naive projection (no
        /// saved field backed this match). The caller binds it to the record on save via `bindField`.
        var isDraft: Bool

        var id: UUID { field.id }
    }

    /// The field a corner correction should edit. When the match resolves to a saved field, that
    /// exact field is returned so the edit re-fits geometry for every match that uses it. Otherwise
    /// the resolved rectangle is wrapped in a draft field to edit and persist. Nil when no field is
    /// resolved.
    func adjustableField() -> AdjustableField? {
        guard canAdjustField, let analytics else { return nil }
        if let saved = fields.store.resolve(recordFieldID: record?.fieldID, track: track) {
            return AdjustableField(field: saved, isDraft: false)
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
        save(record)
    }

    // MARK: - Analysis

    /// Recompute analytics without blocking the main actor, coalescing bursts (e.g. a field edit
    /// fanning out reanalyzes) into at most one in-flight pass plus one follow-up.
    private func scheduleAnalysis() {
        needsReanalyze = true
        guard analyticsTask == nil else { return }
        analyticsTask = Task { [weak self] in
            while let self, self.needsReanalyze {
                self.needsReanalyze = false
                await self.analyze()
            }
            self?.analyticsTask = nil
        }
    }

    private func analyze() async {
        guard let samples else { return }
        let record = record, recorded = recordedInterval, played = playedInterval, format = matchFormat
        let input = MatchAnalysisInput(
            record: record, interval: played, format: format, track: samples.track, heartRate: samples.heartRate,
            healthDistanceMeters: samples.distanceMeters,
            savedField: fields.store.resolve(recordFieldID: record?.fieldID, track: samples.track))
        let (result, track, heartRate, suggestedEnd) = await Task.detached(priority: .userInitiated) {
            let result = MatchAnalyzer.analyze(input)
            let suggestedEnd = record?.trimmedEnd != nil ? nil : TrimAdvisor.suggestedEnd(
                recorded: recorded, track: samples.track, heartRate: samples.heartRate,
                field: result?.hasRoute == true ? result?.rectangle : nil)
            return (result, samples.track.filter { played.contains($0.timestamp) },
                    samples.heartRate.filter { played.contains($0.date) }, suggestedEnd)
        }.value
        analytics = result
        self.track = track
        heartRateSeries = heartRate.map { ($0.date, $0.bpm) }
        suggestedTrimEnd = suggestedEnd
        digest = MatchDigest(id: matchIdentifier, interval: played, format: format, record: record, analytics: result)
        analyticsRevision &+= 1
        onAnalyzed?(self)
    }
}
