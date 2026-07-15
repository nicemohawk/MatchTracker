// MatchStore.swift
// MatchTracker

import Foundation
import HealthKit
import MatchTrackerKit
#if canImport(os)
import os
#endif

/// The handful of values a Matches-list row needs to render its badge (position pill, field name,
/// GPS-route glyph). Persisted once per match so rows render instantly on cold launch instead of
/// triggering a full analytics compute (heatmap / runs / workrate / field-fit) as they scroll in.
struct MatchBadge: Codable, Equatable {
    var role: PositionRole?
    var side: PositionSide?
    var confidence: Double?
    var fieldName: String?
    var hasRoute: Bool
}

/// The minimum a Matches-list row needs to render its top-line numbers (date, duration, distance)
/// with NO HealthKit round-trip. Persisted once per refresh so a cold launch paints the last-known
/// list synchronously from disk, before the anchored HK workout query has returned. Everything else
/// a row shows — field name, route glyph, position — already comes from the badge cache (also loaded
/// synchronously); score / format / reported positions come from the on-disk `MatchRecord`, loaded
/// synchronously too. So this snapshot only needs to carry the workout-derived values HK is the sole
/// source of.
struct PersistedMatchSummary: Codable, Equatable {
    let id: UUID
    let startDate: Date
    let duration: TimeInterval
    let distanceMeters: Double
    /// Whether a real HKWorkout backed this row when persisted (vs a record-only orphan) — lets the
    /// cold list distinguish "route still syncing" rows from genuinely record-only ones.
    let hasWorkout: Bool
}

/// One row in the Matches list: an HK soccer workout joined with its received `MatchRecord`.
/// `workout` is nil for "orphan" record-only matches whose HKWorkout couldn't be fetched
/// (e.g. the route/workout never synced from the watch) — those still appear from the record.
/// It is also nil for a *cold-cache* row rebuilt from `PersistedMatchSummary` before the HK query
/// reconciles; such a row carries `cached` so its numbers render from disk until the workout arrives.
struct MatchSummary: Identifiable {
    let id: UUID
    let workout: HKWorkout?
    let record: MatchRecord?
    /// Persisted display values used to render this row on cold launch, before its HKWorkout has
    /// reconciled from HealthKit. Nil once a real `workout` (or a live refresh) backs the row.
    var cached: PersistedMatchSummary?

    var startDate: Date { workout?.startDate ?? record?.startDate ?? cached?.startDate ?? .distantPast }

    var duration: TimeInterval {
        if let workout { return workout.duration }
        if let record, let end = record.endDate { return end.timeIntervalSince(record.startDate) }
        return cached?.duration ?? 0
    }

    var distanceMeters: Double {
        if let meters = workout?.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meter()) { return meters }
        return cached?.distanceMeters ?? 0
    }

    /// A `PersistedMatchSummary` snapshot of this row's top-line numbers, for the cold-launch cache.
    var persistable: PersistedMatchSummary {
        PersistedMatchSummary(id: id, startDate: startDate, duration: duration,
                              distanceMeters: distanceMeters, hasWorkout: workout != nil)
    }
}

/// Loads soccer workouts from HealthKit, joins them with received match records, and vends
/// cached `MatchDetailModel`s carrying lazily computed analytics.
@MainActor
final class MatchStore: ObservableObject {
    @Published private(set) var matches: [MatchSummary] = []
    @Published private(set) var isLoading = false
    @Published var loadError: String?
    /// True once a full HealthKit refresh has completed at least once this launch. The Matches list
    /// keys its empty state on this: an empty `matches` is only "no matches" AFTER a refresh finished
    /// returning zero — before that (first-ever launch, still loading) it renders skeleton rows.
    @Published private(set) var didCompleteInitialLoad = false
    /// Bumped after every successful refresh. Folded into the list's rebuild signature so the
    /// month-grouped precompute refreshes once when cold-cache rows reconcile into workout-backed
    /// ones, even though the id set (and thus scroll identity) is unchanged.
    @Published private(set) var reconcileToken = 0

    let healthKit: HealthKitService
    let fields: FieldsModel

    private var detailCache: [UUID: MatchDetailModel] = [:]

    /// Persisted row-badge cache (see `MatchBadge`), loaded once from the app-group container so the
    /// Matches list paints without recomputing analytics per row on every cold launch.
    private var badgeCache: [UUID: MatchBadge] = [:]
    private static let badgeCacheFileName = "matchBadges.json"
    /// Persisted lightweight row snapshots (see `PersistedMatchSummary`) so the list paints the
    /// last-known rows synchronously on cold launch, before the HK workout query returns.
    private static let summaryCacheFileName = "matchSummaries.json"

    /// Invoked with newly seen workout UUIDs so the app can auto-upload them.
    var onNewMatches: (([MatchSummary]) -> Void)?

    init(healthKit: HealthKitService = .shared, fields: FieldsModel) {
        self.healthKit = healthKit
        self.fields = fields
        badgeCache = Self.loadBadgeCache()
        // Synchronously rehydrate the last-known list from disk so the first body evaluation renders
        // the full history immediately, then `refresh()` reconciles it against HealthKit in place.
        matches = Self.hydrateFromCache(records: loadRecords())
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        #if DEBUG
        let signposter = OSSignposter(subsystem: "com.nicemohawk.MatchTracker", category: "matchstore")
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("refresh", id: signpostID)
        let refreshStart = Date()
        func mark(_ phase: String, _ since: Date) {
            MatchLog.info("refresh \(phase) took \(String(format: "%.0f", Date().timeIntervalSince(since) * 1000)) ms", category: "matchstore")
        }
        defer { signposter.endInterval("refresh", interval) }
        #endif

        do {
            try await healthKit.requestAuthorization()
            #if DEBUG
            let workoutsStart = Date()
            #endif
            // First paint never waits on this: the cold-cache rows are already on screen. This is the
            // only unavoidably-async phase — one anchored workout-list query. Per-workout route / HR
            // probes stay deferred to row appearance (MatchRow.loadBadge), never batched up-front here.
            let workouts = try await healthKit.fetchSoccerWorkouts()
            #if DEBUG
            mark("fetchSoccerWorkouts (\(workouts.count))", workoutsStart)
            let recordsStart = Date()
            #endif
            let records = loadRecords()
            #if DEBUG
            mark("loadRecords (\(records.count))", recordsStart)
            #endif
            let previousIDs = Set(matches.map(\.id))

            let workoutSummaries = workouts.map { workout in
                MatchSummary(id: workout.uuid, workout: workout, record: records[workout.uuid])
            }
            // Records with no matching HK workout still surface as record-only matches.
            let workoutIDs = Set(workouts.map(\.uuid))
            let orphanSummaries = records.values
                .filter { !workoutIDs.contains($0.id) }
                .map { MatchSummary(id: $0.id, workout: nil, record: $0) }

            // Reconcile in place: same ids in the same order as the cold-cache array, so the swap is
            // a quiet diff (stable identities preserve scroll position) rather than a full reload.
            matches = (workoutSummaries + orphanSummaries).sorted { $0.startDate > $1.startDate }
            didCompleteInitialLoad = true
            reconcileToken &+= 1
            persistSummaries()

            let newlyArrived = matches.filter { !previousIDs.contains($0.id) && $0.record != nil }
            if !previousIDs.isEmpty || !newlyArrived.isEmpty {
                onNewMatches?(newlyArrived)
            }
            #if DEBUG
            mark("total", refreshStart)
            #endif
        } catch {
            loadError = error.localizedDescription
            didCompleteInitialLoad = true
        }
    }

    // MARK: - Cold-launch summary cache

    private static var summaryCacheURL: URL {
        AppGroup.containerURL.appendingPathComponent(summaryCacheFileName)
    }

    /// Rebuild the last-known Matches list synchronously from disk: the persisted row snapshots
    /// (workout-derived numbers) joined with the on-disk records (score / format / positions).
    /// Returns [] on a first-ever launch with no cache, where the list shows skeleton rows instead.
    private static func hydrateFromCache(records: [UUID: MatchRecord]) -> [MatchSummary] {
        guard let data = try? Data(contentsOf: summaryCacheURL),
              let snapshots = try? JSONDecoder().decode([PersistedMatchSummary].self, from: data),
              !snapshots.isEmpty else { return [] }

        let snapshotIDs = Set(snapshots.map(\.id))
        var summaries = snapshots.map { snapshot in
            MatchSummary(id: snapshot.id, workout: nil, record: records[snapshot.id], cached: snapshot)
        }
        // A record that arrived since the last persist (no snapshot yet) still surfaces immediately.
        summaries += records.values
            .filter { !snapshotIDs.contains($0.id) }
            .map { MatchSummary(id: $0.id, workout: nil, record: $0, cached: nil) }

        return summaries.sorted { $0.startDate > $1.startDate }
    }

    private func persistSummaries() {
        let snapshots = matches.map(\.persistable)
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: Self.summaryCacheURL, options: .atomic)
    }

    // MARK: - Row badge cache

    /// The persisted badge for a match, if we've computed it before. Lets a row render instantly
    /// without a HealthKit fetch + analytics compute.
    func cachedBadge(for id: UUID) -> MatchBadge? {
        badgeCache[id]
    }

    /// Store (or refresh) the badge for a match and persist the cache. Called once per match after
    /// its first analytics load.
    func storeBadge(_ badge: MatchBadge, for id: UUID) {
        guard badgeCache[id] != badge else { return }
        badgeCache[id] = badge
        persistBadgeCache()
    }

    private static var badgeCacheURL: URL {
        AppGroup.containerURL.appendingPathComponent(badgeCacheFileName)
    }

    private static func loadBadgeCache() -> [UUID: MatchBadge] {
        guard let data = try? Data(contentsOf: badgeCacheURL),
              let decoded = try? JSONDecoder().decode([UUID: MatchBadge].self, from: data) else { return [:] }
        return decoded
    }

    private func persistBadgeCache() {
        guard let data = try? JSONEncoder().encode(badgeCache) else { return }
        try? data.write(to: Self.badgeCacheURL, options: .atomic)
    }

    /// Cached detail model for a match; call `load()` on it to fetch the track and analytics.
    func detailModel(for summary: MatchSummary) -> MatchDetailModel {
        if let existing = detailCache[summary.id] { return existing }
        let model = MatchDetailModel(summary: summary, healthKit: healthKit, fields: fields)
        // Let the model persist reconciled records (e.g. auto-detected subs) through the store.
        model.persist = { [weak self] record in self?.save(record: record) }
        detailCache[summary.id] = model
        return model
    }

    /// One analyzed match's heatmap plus the metadata the Compare cohort filters on: which venue its
    /// pitch sits in (fields within 250 m cluster into one venue — see `VenueClustering`), its format
    /// (GPS formats never compare against indoor), and when it was played (for the time window).
    struct CohortHeatmapEntry {
        let id: UUID
        let heatmap: HeatmapGrid
        let venue: Int?
        let format: MatchTrackerKit.MatchFormat
        let date: Date
    }

    /// Every OTHER analyzed match's heatmap, tagged with venue / format / date so the Compare view can
    /// build a *like-for-like* cohort instead of averaging the whole cache blindly. Cached details
    /// only — never triggers a HealthKit load, so the cohort grows lazily as matches are opened
    /// (same as today's season average). Indoor / route-less matches carry an empty grid and are
    /// dropped by the shape filter.
    func cohortHeatmapEntries(excluding excludedID: UUID, matchingShapeOf template: HeatmapGrid) -> [CohortHeatmapEntry] {
        let venueMap = VenueClustering.venueMap(fields: fields.fields)
        return detailCache.compactMap { id, model in
            guard id != excludedID, let analytics = model.analytics else { return nil }
            let heatmap = analytics.heatmap
            guard heatmap.columns == template.columns, heatmap.rows == template.rows,
                  !heatmap.cells.isEmpty else { return nil }
            let venue = analytics.rectangle.corners.count == 4
                ? venueMap.venue(forCenter: analytics.rectangle.center)
                : nil
            return CohortHeatmapEntry(id: id, heatmap: heatmap, venue: venue,
                                      format: model.matchFormat, date: model.matchStart)
        }
    }

    /// The peer-cohort average heatmap for the Compare overlay, filtered to matches that are actually
    /// comparable to `detail`, with an honest caption for whatever cohort was used. Walks a fallback
    /// ladder — same venue + format + window, then same format anywhere in the window, then same
    /// format all-time — and always labels which rung it landed on so the caption never lies about
    /// scope. Nil for indoor matches (no GPS to compare) or when no comparable match is cached yet.
    func cohortComparison(for detail: MatchDetailModel, window: CompareWindow) -> CohortComparison? {
        // GPS-only: indoor sessions have no route, so there's nothing to compare on the pitch.
        guard detail.matchFormat != .indoor,
              let analytics = detail.analytics,
              analytics.heatmap.columns > 0, !analytics.heatmap.cells.isEmpty else { return nil }

        let format = detail.matchFormat
        let entries = cohortHeatmapEntries(excluding: detail.matchIdentifier, matchingShapeOf: analytics.heatmap)
        guard !entries.isEmpty else { return nil }

        let venueMap = VenueClustering.venueMap(fields: fields.fields)
        let currentVenue = analytics.rectangle.corners.count == 4
            ? venueMap.venue(forCenter: analytics.rectangle.center) : nil
        let now = Date()

        func build(_ pool: [CohortHeatmapEntry], scope: CohortComparison.Scope) -> CohortComparison? {
            guard let average = Self.averageHeatmap(pool.map(\.heatmap)) else { return nil }
            return CohortComparison(average: average, count: pool.count, scope: scope, window: window)
        }

        // Rung 1: same venue + format, inside the window — the honest "vs N here" cohort.
        if let currentVenue {
            let sameVenue = entries.filter {
                $0.venue == currentVenue && $0.format == format && window.contains($0.date, now: now)
            }
            if sameVenue.count >= 3 { return build(sameVenue, scope: .venue) }
        }
        // Rung 2: same format anywhere, still inside the window.
        let sameFormatInWindow = entries.filter { $0.format == format && window.contains($0.date, now: now) }
        if sameFormatInWindow.count >= 3 { return build(sameFormatInWindow, scope: .anyFieldWindowed) }
        // Rung 3 (safety net): same format, all time — the broadest honest baseline.
        let sameFormat = entries.filter { $0.format == format }
        if !sameFormat.isEmpty { return build(sameFormat, scope: .anyFieldAllTime) }
        return nil
    }

    /// Cell-wise average of same-shaped heatmaps, renormalized so the peak cell is 1 (matching a
    /// single match's grid so the two read on the identical warm ramp). Nil for an empty pool.
    static func averageHeatmap(_ grids: [HeatmapGrid]) -> HeatmapGrid? {
        guard let first = grids.first else { return nil }
        var averaged = first
        let count = Double(grids.count)
        for index in averaged.cells.indices {
            averaged.cells[index] = grids.reduce(0) { $0 + $1.cells[index] } / count
        }
        let peak = averaged.cells.max() ?? 1
        if peak > 0 {
            for index in averaged.cells.indices { averaged.cells[index] /= peak }
        }
        return averaged
    }

    /// The player's season-to-date run norms (mean/σ of run distance and peak speed) pooled across
    /// every OTHER analyzed match currently cached, so a run can be judged unusual for *this*
    /// player. Uses only already-cached analytics — never triggers a HealthKit load — and returns
    /// nil until at least two matches are cached, when a mean/σ would be meaningless.
    func runBaselines(excluding excludedID: UUID) -> RunBaselines? {
        let otherRuns = detailCache
            .filter { $0.key != excludedID }
            .compactMap { $0.value.analytics?.runs }
        guard otherRuns.count >= 2 else { return nil }
        let runs = otherRuns.flatMap { $0 }
        guard runs.count >= 2 else { return nil }

        let (meanDistance, stdDistance) = Self.meanAndStandardDeviation(runs.map(\.distanceMeters))
        let (meanPeak, stdPeak) = Self.meanAndStandardDeviation(runs.map(\.peakSpeed))
        return RunBaselines(meanDistance: meanDistance, stdDistance: stdDistance,
                            meanPeakSpeed: meanPeak, stdPeakSpeed: stdPeak)
    }

    /// Population mean and standard deviation of a non-empty sample.
    private static func meanAndStandardDeviation(_ values: [Double]) -> (mean: Double, std: Double) {
        guard !values.isEmpty else { return (0, 0) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot())
    }

    /// Average workrate score across matches analyzed in the last `days`, for training-load
    /// context. Only already-cached details count — this never triggers HealthKit loads.
    func recentAverageWorkrate(days: Int, excluding excludedID: UUID? = nil) -> Double? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let scores = matches
            .filter { $0.startDate >= cutoff && $0.id != excludedID }
            .compactMap { detailCache[$0.id]?.analytics?.workrate.workrateScore }
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    // MARK: - Match record persistence

    func loadRecords() -> [UUID: MatchRecord] {
        let decoder = MatchTrackerJSON.decoder()
        var result: [UUID: MatchRecord] = [:]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: AppGroup.matchesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(MatchRecord.self, from: data) else { continue }
            result[record.id] = record
        }
        return result
    }

    /// Persist an edited record JSON and refresh the affected summary + detail model.
    func save(record: MatchRecord) {
        let encoder = MatchTrackerJSON.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: AppGroup.matchRecordURL(for: record.id), options: .atomic)

        // The stored badge (position / field / route) may be stale after an edit — drop it so the
        // row recomputes once from the refreshed detail model.
        if badgeCache.removeValue(forKey: record.id) != nil {
            persistBadgeCache()
        }

        if let index = matches.firstIndex(where: { $0.id == record.id }) {
            let summary = MatchSummary(id: record.id, workout: matches[index].workout, record: record)
            matches[index] = summary
            detailCache[record.id]?.updateRecord(record)
        }
    }

    // MARK: - Field-edit invalidation

    /// A saved field's geometry changed (a corner edit — from a match's Adjust Field flow or the
    /// Fields tab). The field rectangle is the projection basis for every match that resolves to it,
    /// so the persisted row badges (position / field name) and the in-memory analytics that back the
    /// season-comparison heatmaps + run baselines are all stale. Without a field → match index we
    /// can't cheaply tell which matches resolve to the edited field, so this clears conservatively:
    /// drop every cached badge (rows recompute lazily on next render) and reproject every cached
    /// detail model (which also refreshes the Compare cohort / `runBaselines`, both derived from it).
    func invalidateForFieldChange() {
        if !badgeCache.isEmpty {
            badgeCache.removeAll()
            persistBadgeCache()
        }
        for model in detailCache.values {
            model.reanalyze()
        }
    }

    static func decodeRecord(from url: URL) -> MatchRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MatchTrackerJSON.decoder().decode(MatchRecord.self, from: data)
    }
}
