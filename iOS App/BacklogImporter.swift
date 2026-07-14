// BacklogImporter.swift
// MatchTracker
//
// Premium batch import that mines the HealthKit backlog. The app already surfaces EVERY historic
// `.soccer` workout as a workout-only match with lazy per-match analytics; this feature turns that
// backlog into durable state: it builds the field database chronologically (oldest → newest, so a
// pitch inferred from an early match refines against later ones), primes season baselines by
// persisting a minimal `MatchRecord` for each workout, and — opt-in — recovers matches that were
// mistakenly recorded as outdoor runs/walks.
//
// Honest about the data: native `.soccer` workouts carry NO `HKWorkoutRoute` (Apple only saves
// routes for run/walk/cycle/hike). Those route-less matches still import — the record is written
// with `format = .indoor` so the analyzer's heart-rate-only effort path engages (it renders as an
// "Indoor session"; a v1 compromise, since the batch UX can't place a field it can't see).

import Foundation
import HealthKit
import MatchTrackerKit

@MainActor
@Observable
final class BacklogImporter {
    // MARK: - Scan results (free tier)

    /// Workout-only `.soccer` matches (no `MatchRecord` on disk) available to import.
    private(set) var pendingCount = 0
    /// Of `pendingCount`, how many carry a GPS route (full-field analytics) vs. heart-rate only.
    private(set) var withRouteCount = 0
    private(set) var withoutRouteCount = 0
    /// True when the route split was estimated from a sample of a large backlog rather than counted.
    private(set) var routeCountIsApproximate = false
    /// Oldest pending workout's date, for the "since <month year>" span copy.
    private(set) var earliestDate: Date?

    // MARK: - Import progress (gated)

    private(set) var isImporting = false
    private(set) var completed = 0
    private(set) var total = 0
    /// The date of the workout currently being processed, shown as the batch scrubs through history.
    private(set) var currentDate: Date?
    private(set) var summary: Summary?
    /// Set the moment a completed full import is recorded, so the teaser can hide immediately.
    private(set) var hasImported: Bool

    private var isCancelled = false
    private var didScan = false

    struct Summary: Equatable {
        var soccerImported: Int          // records created for `.soccer` workouts
        var routelessImported: Int       // subset of the above with no route (HR-only / indoor path)
        var recoveredFromRuns: Int       // matches rescued from mis-recorded runs/walks
        var fieldsCreated: Int           // new `.inferred` fields auto-saved during the batch
        var fieldsRefined: Int           // existing fields whose geometry was refined
        var earliest: Date?
        var latest: Date?
        var cancelled: Bool

        var totalMatches: Int { soccerImported + recoveredFromRuns }
    }

    private let matches: MatchStore
    private let fields: FieldsModel
    private var healthKit: HealthKitService { matches.healthKit }

    private let defaults: UserDefaults
    private static let completedKey = "backlogImportCompletedAt"

    /// Only sample this many workouts for the route split before extrapolating (keeps `scan` cheap
    /// on a very large backlog — a limit-1 route query per workout otherwise adds up).
    private static let routeSampleCap = 80
    /// Disguised-match candidates: outdoor runs/walks lasting a plausible match length.
    private static let minRunDuration: TimeInterval = 30 * 60
    private static let maxRunDuration: TimeInterval = 150 * 60

    init(matches: MatchStore, fields: FieldsModel) {
        self.matches = matches
        self.fields = fields
        self.defaults = UserDefaults(suiteName: AppGroup.identifier) ?? .standard
        self.hasImported = defaults.object(forKey: Self.completedKey) != nil
    }

    // MARK: - Scan (free)

    /// Runs `scan()` once per launch; safe to attach to a view's `.task`. Re-enabled after an import
    /// so the numbers refresh.
    func scanIfNeeded() async {
        guard !didScan else { return }
        didScan = true
        await scan()
    }

    /// Count workout-only `.soccer` matches and estimate their route coverage. Cheap: it reuses the
    /// existing workout fetch and, at most, a limit-1 route-existence query per sampled workout — it
    /// never loads a full route/track. Degrades to `pendingCount = 0` when HealthKit is unavailable
    /// or denied, so the teaser simply stays hidden.
    func scan() async {
        guard healthKit.isHealthDataAvailable else {
            resetScan()
            return
        }
        do {
            let workouts = try await healthKit.fetchSoccerWorkouts()
            let records = matches.loadRecords()
            let pending = workouts
                .filter { records[$0.uuid] == nil }
                .sorted { $0.startDate < $1.startDate }

            pendingCount = pending.count
            earliestDate = pending.first?.startDate

            guard !pending.isEmpty else {
                withRouteCount = 0
                withoutRouteCount = 0
                routeCountIsApproximate = false
                return
            }

            // Sample route existence (native soccer has none; third-party apps may). Extrapolate
            // beyond the cap so a huge backlog doesn't fan out into hundreds of queries.
            let sample = Array(pending.suffix(Self.routeSampleCap))
            var routed = 0
            for workout in sample {
                routed += await routeExists(for: workout) ? 1 : 0
            }
            if pending.count > sample.count {
                let ratio = Double(routed) / Double(sample.count)
                withRouteCount = Int((ratio * Double(pending.count)).rounded())
                routeCountIsApproximate = true
            } else {
                withRouteCount = routed
                routeCountIsApproximate = false
            }
            withoutRouteCount = max(0, pending.count - withRouteCount)
        } catch {
            MatchLog.error("Backlog scan failed: \(error.localizedDescription)", category: "backlog")
            resetScan()
        }
    }

    private func resetScan() {
        pendingCount = 0
        withRouteCount = 0
        withoutRouteCount = 0
        routeCountIsApproximate = false
        earliestDate = nil
    }

    // MARK: - Import (gated — callers must confirm entitlement before invoking)

    func cancel() { isCancelled = true }

    /// Chronological batch over pending workouts. For each: fetch the track, fold it into the field
    /// database (`recordObservation` — refine a match, auto-save an inference), then persist a
    /// minimal `MatchRecord` so subsequent loads join it. Analytics stay lazy — nothing here forces
    /// a detail-model load. Serial with a yield between items so the UI breathes; cancellable;
    /// failures are logged and skipped. When `includeDisguisedRuns` is set it additionally rescues
    /// outdoor runs/walks whose GPS track fits a pitch.
    ///
    /// Gating lives with the caller (mirroring how CoachDashboard is gated in `MatchesView`): the
    /// import sheet only reaches this when `entitlements.entitledToTeam`.
    func importAll(includeDisguisedRuns: Bool) async {
        guard !isImporting, healthKit.isHealthDataAvailable else { return }
        isImporting = true
        isCancelled = false
        completed = 0
        currentDate = nil
        summary = nil
        defer { isImporting = false }

        let records = matches.loadRecords()

        let pendingSoccer: [HKWorkout]
        do {
            pendingSoccer = try await healthKit.fetchSoccerWorkouts()
                .filter { records[$0.uuid] == nil }
                .sorted { $0.startDate < $1.startDate }
        } catch {
            MatchLog.error("Backlog import: soccer fetch failed: \(error.localizedDescription)", category: "backlog")
            return
        }

        let disguisedCandidates = includeDisguisedRuns
            ? await fetchDisguisedRunCandidates(existingRecords: records)
            : []

        total = pendingSoccer.count + disguisedCandidates.count

        var soccerImported = 0
        var routelessImported = 0
        var recoveredFromRuns = 0
        var fieldsCreated = 0
        var fieldsRefined = 0
        var earliest: Date?
        var latest: Date?

        func note(date: Date) {
            if earliest == nil || date < earliest! { earliest = date }
            if latest == nil || date > latest! { latest = date }
        }

        // 1. Soccer backlog (oldest first).
        for workout in pendingSoccer {
            if isCancelled { break }
            currentDate = workout.startDate
            do {
                let track = try await healthKit.fetchTrack(for: workout)
                var fieldID: UUID?
                if !track.isEmpty {
                    switch fields.store.recordObservation(track: track) {
                    case .matched(let field):
                        fieldID = field.id
                        fieldsRefined += 1
                    case .proposed(var field):
                        fieldsCreated += 1
                        field.name = "Imported field \(fieldsCreated)"   // source is already .inferred
                        fields.save(field, pushToWatch: false)
                        fieldID = field.id
                    case .none:
                        break
                    }
                }
                // Route-less native soccer: no track to place onto. Persist as `.indoor` so the
                // heart-rate-only workrate path engages instead of leaving the match un-analyzable.
                let format: MatchTrackerKit.MatchFormat? = track.isEmpty ? .indoor : nil
                if track.isEmpty { routelessImported += 1 }

                let record = MatchRecord(
                    id: workout.uuid, startDate: workout.startDate, endDate: workout.endDate,
                    fieldID: fieldID, events: [], teamCode: nil, format: format
                )
                matches.save(record: record)
                soccerImported += 1
                note(date: workout.startDate)
            } catch {
                MatchLog.error("Backlog import: soccer \(workout.uuid.uuidString.prefix(8)) failed: \(error.localizedDescription)",
                               category: "backlog")
            }
            completed += 1
            await Task.yield()
        }

        // 2. Disguised-match recovery (opt-in). The track is already loaded by the classifier; reuse
        //    it for field observation, then persist a full `.match` record.
        for candidate in disguisedCandidates {
            if isCancelled { break }
            currentDate = candidate.workout.startDate
            switch fields.store.recordObservation(track: candidate.track) {
            case .matched:
                fieldsRefined += 1
            case .proposed(var field):
                fieldsCreated += 1
                field.name = "Imported field \(fieldsCreated)"
                fields.save(field, pushToWatch: false)
            case .none:
                break
            }
            let bestMatch = fields.store.bestMatch(for: candidate.track.map(\.coordinate))
            let record = MatchRecord(
                id: candidate.workout.uuid, startDate: candidate.workout.startDate,
                endDate: candidate.workout.endDate, fieldID: bestMatch?.id,
                events: [], teamCode: nil, format: .match
            )
            matches.save(record: record)
            recoveredFromRuns += 1
            note(date: candidate.workout.startDate)
            completed += 1
            await Task.yield()
        }

        // Push the freshly built/refined fields to the watch + backend via the existing hook, and
        // refresh the match list so every new record joins its workout.
        fields.reload()
        fields.onFieldsChanged?()
        await matches.refresh()

        summary = Summary(
            soccerImported: soccerImported, routelessImported: routelessImported,
            recoveredFromRuns: recoveredFromRuns, fieldsCreated: fieldsCreated,
            fieldsRefined: fieldsRefined, earliest: earliest, latest: latest, cancelled: isCancelled
        )

        // Reflect the drained backlog and, on a full pass, record completion so the teaser hides.
        pendingCount = max(0, pendingCount - soccerImported)
        withoutRouteCount = max(0, withoutRouteCount - routelessImported)
        withRouteCount = max(0, pendingCount - withoutRouteCount)
        didScan = false
        if !isCancelled {
            defaults.set(Date(), forKey: Self.completedKey)
            hasImported = true
        }
        MatchLog.info("Backlog import finished: \(soccerImported) soccer (\(routelessImported) HR-only), \(recoveredFromRuns) recovered, fields +\(fieldsCreated)/~\(fieldsRefined)\(isCancelled ? " (cancelled)" : "")",
                      category: "backlog")
    }

    // MARK: - Disguised-match recovery

    private struct RunCandidate {
        let workout: HKWorkout
        let track: [TrackPoint]
    }

    /// Outdoor runs/walks of a plausible match length whose GPS track is confined to a pitch-shaped
    /// area (`FieldGeometry.inferFieldRectangle` succeeds). This is the expensive path — a full route
    /// load per candidate — so it runs inside the batch, oldest first, and is cancellable.
    private func fetchDisguisedRunCandidates(existingRecords: [UUID: MatchRecord]) async -> [RunCandidate] {
        var workouts: [HKWorkout] = []
        for activity in [HKWorkoutActivityType.running, .walking] {
            let fetched = (try? await fetchWorkouts(activityType: activity)) ?? []
            workouts.append(contentsOf: fetched)
        }
        let plausible = workouts
            .filter { existingRecords[$0.uuid] == nil }
            .filter { $0.duration >= Self.minRunDuration && $0.duration <= Self.maxRunDuration }
            .filter { ($0.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) != true }
            .sorted { $0.startDate < $1.startDate }

        var candidates: [RunCandidate] = []
        for workout in plausible {
            if isCancelled { break }
            currentDate = workout.startDate
            guard let track = try? await healthKit.fetchTrack(for: workout), !track.isEmpty,
                  FieldGeometry.inferFieldRectangle(from: track) != nil else { continue }
            candidates.append(RunCandidate(workout: workout, track: track))
            await Task.yield()
        }
        return candidates
    }

    // MARK: - HealthKit helpers (kept local so HealthKitService stays untouched)

    private func fetchWorkouts(activityType: HKWorkoutActivityType) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForWorkouts(with: activityType)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: .workoutType(), predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (results as? [HKWorkout]) ?? [])
            }
            healthKit.healthStore.execute(query)
        }
    }

    /// Cheap route-existence probe (limit-1 sample query). Never loads route points.
    private func routeExists(for workout: HKWorkout) async -> Bool {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(), predicate: predicate,
                limit: 1, sortDescriptors: nil
            ) { _, results, _ in
                continuation.resume(returning: (results?.isEmpty == false))
            }
            healthKit.healthStore.execute(query)
        }
    }
}
