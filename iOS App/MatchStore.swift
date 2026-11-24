// MatchStore.swift
// MatchTracker

import UIKit
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
    /// The analysis's distance. Optional for back-compat.
    var routeDistanceMeters: Double?
    /// Set when a field edit invalidates the field-derived parts (name, position). A stale badge
    /// still seeds the row instantly — crucially `hasRoute`, which no field edit can change — while
    /// the row recomputes and re-stores a fresh one.
    var stale: Bool?
}

/// The minimum a Matches-list row needs to render its top-line numbers (date, duration, distance)
/// with NO HealthKit round-trip. Persisted once per refresh so a cold launch paints the last-known
/// list synchronously from disk, before the anchored HK workout query has returned. Everything else
/// a row shows — field name, route glyph, position — comes from the badge cache; score / format /
/// reported positions come from the on-disk `MatchRecord`s. Both of those decode asynchronously
/// off the pre-paint path and attach moments later. So this snapshot only needs to carry the
/// workout-derived values HK is the sole source of.
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
        if let record, record.trimmedStart != nil || record.trimmedEnd != nil {
            return record.played(within: recordedInterval).duration
        }
        if let workout { return workout.duration }
        if let record, let end = record.endDate { return end.timeIntervalSince(record.startDate) }
        return cached?.duration ?? 0
    }

    var distanceMeters: Double {
        if let meters = workout?.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meter()) { return meters }
        return cached?.distanceMeters ?? 0
    }

    /// Whether there is anything to read the match from. Not yet for a cold-cache row still waiting
    /// for the workout it is known to have.
    var hasSource: Bool { workout != nil || (record != nil && cached?.hasWorkout != true) }

    var format: MatchTrackerKit.MatchFormat { Self.format(workout: workout, record: record) }

    /// The whole recording, before any trim.
    var recordedInterval: DateInterval { Self.recordedInterval(workout: workout, record: record) }

    static func format(workout: HKWorkout?, record: MatchRecord?) -> MatchTrackerKit.MatchFormat {
        if let format = record?.format { return format }
        return workout?.metadata?[HKMetadataKeyIndoorWorkout] as? Bool == true ? .indoor : .match
    }

    static func recordedInterval(workout: HKWorkout?, record: MatchRecord?) -> DateInterval {
        let start = record?.startDate ?? workout?.startDate ?? .distantPast
        let end = record?.endDate ?? workout?.endDate ?? start
        return DateInterval(start: start, end: max(start, end))
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
    /// Monotonic version of the list's inputs: bumped on any `matches` mutation and when the async
    /// badge-cache decode lands. The Matches list keys its precompute rebuild on this instead of
    /// hashing every match id per body evaluation.
    @Published private(set) var contentVersion = 0

    let healthKit: HealthKitService
    let fields: FieldsModel

    private var detailCache: [UUID: MatchDetailModel] = [:]

    /// Persisted row-badge cache (see `MatchBadge`), decoded asynchronously off the pre-paint path
    /// (its consumers all run post-paint) so the Matches list paints without recomputing analytics
    /// per row on every cold launch.
    private var badgeCache: [UUID: MatchBadge] = [:]
    /// The in-flight badge-cache decode; `loadedBadge(for:)` awaits it so the expensive per-row
    /// cold path never fires just because the cache "looks empty" while still loading.
    private var badgeCacheLoadTask: Task<Void, Never>?
    /// Every match's digest, for lists, seasons and comparisons: nothing that reads these has to
    /// open a route. Loaded from disk at launch, filled and refreshed in the background.
    @Published private(set) var digests: [UUID: MatchDigest] = [:]
    private var digestCache = DigestCache()
    private nonisolated static let digestCacheFileName = "matchDigests.json"
    private var digestLoadTask: Task<Void, Never>?
    private var digestFillTask: Task<Void, Never>?
    private var needsAnotherDigestFill = false
    /// Matches not worth reading again this launch: they failed, or still have no route.
    private var digestsTriedThisLaunch: Set<UUID> = []
    private var protectedDataObserver: NSObjectProtocol?

    private nonisolated static let badgeCacheFileName = "matchBadges.json"
    /// Persisted lightweight row snapshots (see `PersistedMatchSummary`) so the list paints the
    /// last-known rows synchronously on cold launch, before the HK workout query returns.
    private nonisolated static let summaryCacheFileName = "matchSummaries.json"

    /// Ids of deleted matches whose HKWorkout couldn't be deleted (HealthKit only lets an app
    /// delete objects it saved itself), persisted so those workouts never resurface on refresh.
    /// Tiny — loaded synchronously at init.
    private var hiddenMatchIDs: Set<UUID>
    private nonisolated static let hiddenMatchesFileName = "hiddenMatches.json"

    /// Invoked with newly seen workout UUIDs so the app can auto-upload them.
    var onNewMatches: (([MatchSummary]) -> Void)?

    init(healthKit: HealthKitService = .shared, fields: FieldsModel) {
        self.healthKit = healthKit
        self.fields = fields
        let hiddenIDs = Self.loadHiddenMatchIDs()
        hiddenMatchIDs = hiddenIDs
        // Synchronously rehydrate the last-known list from the summary snapshots alone — one small
        // file, no per-record decode — so the first body evaluation renders the full history
        // immediately. Records and badges decode off the main actor and attach post-paint;
        // `refresh()` then reconciles everything against HealthKit in place. Hidden (deleted)
        // matches are filtered here so a stale snapshot never flashes them back post-delete.
        matches = Self.hydrateFromCache().filter { !hiddenIDs.contains($0.id) }

        badgeCacheLoadTask = Task(priority: .userInitiated) { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { Self.loadBadgeCache() }.value
            guard let self, !loaded.isEmpty else { return }
            // Badges stored while the decode was in flight are fresher — they win the merge.
            self.badgeCache = loaded.merging(self.badgeCache) { _, fresh in fresh }
            self.contentVersion &+= 1
        }
        digestLoadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { Self.loadDigestCache() }.value
            guard let self else { return }
            digestCache.entries.merge(loaded.entries) { fresh, _ in fresh }
            digests = digestCache.entries.mapValues(\.digest)
        }
        // HealthKit is closed while the phone is locked; carry on when it opens.
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.fillDigests() }
        }
        initialRecordsAttach = Task(priority: .userInitiated) { [weak self] in
            let records = await Task.detached(priority: .userInitiated) { Self.loadRecordsFromDisk() }.value
            self?.attach(records: records)
        }
    }

    /// The init-time record load + attach. `refresh()` awaits it before diffing "newly arrived"
    /// matches, so records already on disk at launch are never mistaken for new arrivals.
    private var initialRecordsAttach: Task<Void, Never>?

    /// Join freshly loaded records onto the cold-cache rows (which start record-less) and surface
    /// records that have no snapshot yet. No-op once `refresh()` has already reconciled.
    private func attach(records: [UUID: MatchRecord]) {
        guard !records.isEmpty else { return }
        var updated = false
        var merged = matches.map { summary -> MatchSummary in
            guard summary.record == nil, let record = records[summary.id] else { return summary }
            updated = true
            return MatchSummary(id: summary.id, workout: summary.workout, record: record,
                                cached: summary.cached)
        }
        let knownIDs = Set(matches.map(\.id))
        let extras = records.values
            .filter { !knownIDs.contains($0.id) }
            .map { MatchSummary(id: $0.id, workout: nil, record: $0) }
        if !extras.isEmpty {
            merged = (merged + extras).sorted { $0.startDate > $1.startDate }
            updated = true
        }
        guard updated else { return }
        matches = merged
        contentVersion &+= 1
        updateDetailModels()
    }

    /// Hand open matches what the list just learned, so one opened before its workout or record
    /// arrived doesn't stay empty.
    private func updateDetailModels() {
        for summary in matches {
            detailCache[summary.id]?.update(from: summary)
        }
    }

    /// Workouts as the list shows them: no deleted ones, and one per match when two apps recorded it.
    func fetchListedWorkouts(records: [UUID: MatchRecord]) async throws -> [HKWorkout] {
        listed(try await healthKit.fetchMatchWorkouts(), records: records)
    }

    private func listed(_ workouts: [HKWorkout], records: [UUID: MatchRecord]) -> [HKWorkout] {
        let duplicates = WorkoutSpan.duplicates(among: workouts.map { workout in
            let record = records[workout.uuid]
            let recorded = MatchSummary.recordedInterval(workout: workout, record: record)
            return WorkoutSpan(id: workout.uuid, interval: record?.played(within: recorded) ?? recorded,
                               sourceIdentifier: workout.sourceIdentifier, hasRecord: record != nil)
        })
        return workouts.filter { !hiddenMatchIDs.contains($0.uuid) && !duplicates.contains($0.uuid) }
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
            let workouts = try await healthKit.fetchMatchWorkouts()
            #if DEBUG
            mark("fetchMatchWorkouts (\(workouts.count))", workoutsStart)
            let recordsStart = Date()
            #endif
            let loadedRecords = await Task.detached(priority: .userInitiated) { Self.loadRecordsFromDisk() }.value
            #if DEBUG
            mark("loadRecords (\(loadedRecords.count))", recordsStart)
            #endif
            // Let the init-time attach land first so launch-present records never read as new.
            await initialRecordsAttach?.value
            let previousIDs = Set(matches.map(\.id))

            let workoutIDs = Set(workouts.map(\.uuid))
            // Heal records whose id never matched their workout's uuid (failed finishWorkout(),
            // older watch builds) so they join instead of ghosting as a duplicate row.
            let records = adoptOrphanRecords(loadedRecords, workouts: workouts, workoutIDs: workoutIDs)

            let workoutSummaries = listed(workouts, records: records).map { workout in
                MatchSummary(id: workout.uuid, workout: workout, record: records[workout.uuid])
            }
            // Records with no matching HK workout still surface as record-only matches.
            let orphanSummaries = records.values
                .filter { !workoutIDs.contains($0.id) && !hiddenMatchIDs.contains($0.id) }
                .map { MatchSummary(id: $0.id, workout: nil, record: $0) }

            // Reconcile in place: same ids in the same order as the cold-cache array, so the swap is
            // a quiet diff (stable identities preserve scroll position) rather than a full reload.
            matches = (workoutSummaries + orphanSummaries).sorted { $0.startDate > $1.startDate }
            didCompleteInitialLoad = true
            reconcileToken &+= 1
            contentVersion &+= 1
            schedulePersistSummaries()
            updateDetailModels()
            // No workouts at all is more likely a permission than a season deleted.
            if !workouts.isEmpty { forgetDigests(except: Set(matches.map(\.id))) }
            fillDigests()

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
            for model in detailCache.values { model.sourceUnavailable() }
        }
    }

    // MARK: - Cold-launch summary cache

    nonisolated private static var summaryCacheURL: URL {
        AppGroup.containerURL.appendingPathComponent(summaryCacheFileName)
    }

    /// Rebuild the last-known Matches list synchronously from the persisted row snapshots (which
    /// cover every match, orphans included — `schedulePersistSummaries` maps the full array). Rows
    /// start record-less; `attach(records:)` joins the score / format / positions once the record
    /// decode lands. Returns [] on a first-ever launch with no cache (skeleton rows show instead).
    private static func hydrateFromCache() -> [MatchSummary] {
        guard let data = try? Data(contentsOf: summaryCacheURL),
              let snapshots = try? JSONDecoder().decode([PersistedMatchSummary].self, from: data)
        else { return [] }
        // Snapshots are persisted pre-sorted — no re-sort needed.
        return snapshots.map { MatchSummary(id: $0.id, workout: nil, record: nil, cached: $0) }
    }

    private var pendingSummaryPersist: Task<Void, Never>?
    private var summaryPersistDirty = false

    /// Debounced, off-main snapshot persist: bursts of refreshes (e.g. several watch-received
    /// records in a row) coalesce into one encode + atomic write, and the encode — which walks
    /// `persistable`, doing a HealthKit statistics lookup per row — never runs on the main actor
    /// (HKWorkout is immutable, safe to read from any thread).
    private func schedulePersistSummaries() {
        summaryPersistDirty = true
        pendingSummaryPersist?.cancel()
        pendingSummaryPersist = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.summaryPersistDirty = false
            Self.writeSummaries(self.matches)
        }
    }

    private nonisolated static func writeSummaries(_ summaries: [MatchSummary]) {
        Task.detached(priority: .utility) {
            let snapshots = summaries.map(\.persistable)
            guard let data = try? JSONEncoder().encode(snapshots) else { return }
            try? data.write(to: summaryCacheURL, options: .atomic)
        }
    }

    // MARK: - Row badge cache

    /// The persisted badge for a match, if we've computed it before. Lets a row render instantly
    /// without a HealthKit fetch + analytics compute.
    func cachedBadge(for id: UUID) -> MatchBadge? {
        badgeCache[id]
    }

    /// `cachedBadge(for:)`, but awaiting the async cache decode first — for callers about to run
    /// the expensive cold path, so a still-loading cache is never mistaken for a cache miss.
    func loadedBadge(for id: UUID) async -> MatchBadge? {
        await badgeCacheLoadTask?.value
        return badgeCache[id]
    }

    /// Store (or refresh) the badge for a match and persist the cache. Called once per match after
    /// its first analytics load.
    func storeBadge(_ badge: MatchBadge, for id: UUID) {
        // A cold-launch row has nothing true to say about its route.
        guard badgeCache[id] != badge,
              matches.contains(where: { $0.id == id && $0.hasSource }) else { return }
        badgeCache[id] = badge
        schedulePersistBadgeCache()
    }

    nonisolated private static var badgeCacheURL: URL {
        AppGroup.containerURL.appendingPathComponent(badgeCacheFileName)
    }

    nonisolated private static func loadBadgeCache() -> [UUID: MatchBadge] {
        guard let data = try? Data(contentsOf: badgeCacheURL),
              let decoded = try? JSONDecoder().decode([UUID: MatchBadge].self, from: data) else { return [:] }
        // Distances stored before they had one definition don't match anything else on screen.
        return decoded.mapValues { badge in
            var badge = badge
            badge.routeDistanceMeters = nil
            return badge
        }
    }

    private var pendingBadgePersist: Task<Void, Never>?
    private var badgePersistDirty = false

    /// Debounced, off-main badge-cache persist: a first full scroll stores a badge per row, so
    /// writing the whole dict per store would be O(n²) write volume — coalesce into one write.
    private func schedulePersistBadgeCache() {
        badgePersistDirty = true
        pendingBadgePersist?.cancel()
        pendingBadgePersist = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.badgePersistDirty = false
            Self.writeBadgeCache(self.badgeCache)
        }
    }

    private nonisolated static func writeBadgeCache(_ cache: [UUID: MatchBadge]) {
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(cache) else { return }
            try? data.write(to: badgeCacheURL, options: .atomic)
        }
    }

    /// Flush any debounced cache writes immediately (skipping the remaining delay) — called when
    /// the app backgrounds so a pending persist isn't lost if the process is killed.
    func flushPendingPersists() {
        if badgePersistDirty {
            pendingBadgePersist?.cancel()
            badgePersistDirty = false
            Self.writeBadgeCache(badgeCache)
        }
        if summaryPersistDirty {
            pendingSummaryPersist?.cancel()
            summaryPersistDirty = false
            Self.writeSummaries(matches)
        }
        if digestPersistDirty {
            pendingDigestPersist?.cancel()
            digestPersistDirty = false
            Self.writeDigestCache(digestCache)
        }
    }

    // MARK: - Digests

    func digest(for id: UUID) -> MatchDigest? { digests[id] }

    /// Every match.
    var season: SeasonSummary { SeasonSummary(Array(digests.values)) }

    func season(_ term: SeasonSummary.Term) -> SeasonSummary {
        SeasonSummary(digests.values.filter { SeasonSummary.Term(containing: $0.startDate) == term })
    }

    /// The seasons there are matches in, newest first.
    var terms: [SeasonSummary.Term] {
        Set(digests.values.map { SeasonSummary.Term(containing: $0.startDate) }).sorted(by: >)
    }

    /// The most interesting true thing about a match. Nil before its digest, or when there's nothing to say.
    /// The most recent match, if any has been read yet.
    var latestDigest: MatchDigest? { digests.values.max { $0.startDate < $1.startDate } }

    func headline(for id: UUID) -> String? {
        digests[id].flatMap { MatchHeadline.make(for: $0, among: Array(digests.values)) }
    }

    /// A match's one distance; nil when nothing measured it.
    func distanceMeters(for summary: MatchSummary) -> Double? {
        digests[summary.id]?.distanceMeters ?? (summary.distanceMeters > 0 ? summary.distanceMeters : nil)
    }

    nonisolated private static var digestCacheURL: URL {
        AppGroup.containerURL.appendingPathComponent(digestCacheFileName)
    }

    nonisolated private static func loadDigestCache() -> DigestCache {
        guard let data = try? Data(contentsOf: digestCacheURL) else { return DigestCache() }
        return (try? MatchTrackerJSON.decoder().decode(DigestCache.self, from: data)) ?? DigestCache()
    }

    private var pendingDigestPersist: Task<Void, Never>?
    private var digestPersistDirty = false

    private func schedulePersistDigests() {
        digestPersistDirty = true
        pendingDigestPersist?.cancel()
        pendingDigestPersist = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.digestPersistDirty = false
            Self.writeDigestCache(self.digestCache)
        }
    }

    private nonisolated static func writeDigestCache(_ cache: DigestCache) {
        Task.detached(priority: .utility) {
            guard let data = try? MatchTrackerJSON.encoder().encode(cache) else { return }
            try? data.write(to: digestCacheURL, options: .atomic)
        }
    }

    private func store(_ entries: [UUID: DigestCache.Entry]) {
        guard !entries.isEmpty else { return }
        digestCache.entries.merge(entries) { _, fresh in fresh }
        digests.merge(entries.mapValues(\.digest)) { _, fresh in fresh }
        schedulePersistDigests()
    }

    private func forgetDigests(except ids: Set<UUID>) {
        let gone = digestCache.entries.keys.filter { !ids.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone {
            digestCache.entries[id] = nil
            digests[id] = nil
        }
        schedulePersistDigests()
    }

    /// Compute whatever digests are missing or out of date, in the background: newest first, one at
    /// a time. A phone that locks partway stops it; unlocking or the next refresh resumes it.
    private func fillDigests() {
        guard digestFillTask == nil else {
            needsAnotherDigestFill = true
            return
        }
        digestFillTask = Task(priority: .background) { [weak self] in
            await self?.runDigestFill()
            guard let self else { return }
            digestFillTask = nil
            if needsAnotherDigestFill {
                needsAnotherDigestFill = false
                fillDigests()
            }
        }
    }

    private func runDigestFill() async {
        await digestLoadTask?.value
        let stale = await staleDigests()
        guard !stale.isEmpty else { return }
        MatchLog.info("digests: \(stale.count) to compute", category: "matchstore")

        // Published a dozen at a time: each publish re-evaluates every view watching the store.
        var pending: [UUID: DigestCache.Entry] = [:]
        defer { store(pending) }
        for summary in stale {
            // An open match keeps its own digest up to date.
            if detailCache[summary.id]?.digest != nil { continue }
            do {
                let entry = try await digestEntry(for: summary)
                pending[summary.id] = entry
                // A route can reach the phone after its workout; look again next launch.
                if !entry.digest.hasRoute { digestsTriedThisLaunch.insert(summary.id) }
            } catch where HealthKitService.isLocked(error) {
                MatchLog.info("digests: paused, health data is locked", category: "matchstore")
                return
            } catch {
                MatchLog.error("digests: \(summary.id) failed: \(error.localizedDescription)", category: "matchstore")
                digestsTriedThisLaunch.insert(summary.id)
            }
            if pending.count >= 12 {
                store(pending)
                pending = [:]
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func staleDigests() async -> [MatchSummary] {
        let cache = digestCache, fields = fields.fields, tried = digestsTriedThisLaunch
        let candidates = matches.filter(\.hasSource)
        let recently = Date().addingTimeInterval(-7 * 86_400)
        let awaitingRoute = Set(candidates.filter { summary in
            summary.startDate > recently && summary.format != .indoor
                && summary.workout?.sourceIdentifier.hasPrefix(WorkoutSpan.ownSourcePrefix) == true
                && cache.entries[summary.id]?.digest.hasRoute == false
        }.map(\.id))
        // Off the main actor: stamping a record encodes it.
        let records = candidates.map { (id: $0.id, record: $0.record) }
        let staleIDs = await Task.detached(priority: .background) {
            Set(records.filter { id, record in
                guard cache.isCurrent(id, record: record, fields: fields) else { return true }
                return awaitingRoute.contains(id)
            }.map(\.id))
        }.value
        return candidates
            .filter { summary in
                staleIDs.contains(summary.id)
                    // Once a launch, unless an edit has made what's stored wrong rather than incomplete.
                    && !(tried.contains(summary.id) && (cache.entries[summary.id] == nil || awaitingRoute.contains(summary.id)))
            }
            .sorted { $0.startDate > $1.startDate }
    }

    private func digestEntry(for summary: MatchSummary) async throws -> DigestCache.Entry {
        let record = summary.record, recorded = summary.recordedInterval, format = summary.format
        let played = record?.played(within: recorded) ?? recorded
        let samples = try await healthKit.fetchSamples(for: summary.workout, record: record,
                                                       recorded: recorded, played: played)
        let input = MatchAnalysisInput(
            record: record, interval: played, format: format, track: samples.track, heartRate: samples.heartRate,
            healthDistanceMeters: samples.distanceMeters,
            savedField: fields.store.resolve(recordFieldID: record?.fieldID, track: samples.track))
        let fields = fields.fields
        return await Task.detached(priority: .background) {
            let analytics = MatchAnalyzer.analyze(input)
            return DigestCache.Entry(
                digest: MatchDigest(id: summary.id, interval: played, format: format, record: record, analytics: analytics),
                record: record, center: analytics?.hasRoute == true ? analytics?.rectangle.center : nil, fields: fields)
        }.value
    }

    /// Keep what an open match just worked out.
    private func storeDigest(of model: MatchDetailModel) {
        guard let digest = model.digest else { return }
        let center = model.analytics?.hasRoute == true ? model.analytics?.rectangle.center : nil
        store([digest.id: DigestCache.Entry(digest: digest, record: model.record, center: center, fields: fields.fields)])
    }

    /// Cached detail model for a match; call `load()` on it to fetch the track and analytics.
    func detailModel(for summary: MatchSummary) -> MatchDetailModel {
        if let existing = detailCache[summary.id] { return existing }
        // A view may still be holding the row as it was before its workout arrived.
        let summary = matches.first { $0.id == summary.id } ?? summary
        let model = MatchDetailModel(summary: summary, healthKit: healthKit, fields: fields)
        // Let the model persist reconciled records (e.g. auto-detected subs) through the store.
        model.persist = { [weak self] record in self?.save(record: record) }
        model.onAnalyzed = { [weak self] model in self?.storeDigest(of: model) }
        model.refreshMatches = { [weak self] in await self?.refresh() }
        model.makeHeadline = { [weak self] digest in
            self.flatMap { MatchHeadline.make(for: digest, among: Array($0.digests.values)) }
        }
        detailCache[summary.id] = model
        return model
    }

    /// Memoized venue clustering — O(fields²) to build, so it's cached until the saved fields
    /// change. Keyed by field ids AND centers, catching geometry edits that keep the same id set
    /// (e.g. watch-received field updates that bypass `invalidateForFieldChange`).
    private var venueMapCache: (ids: [UUID], centers: [Coordinate2D], map: VenueMap)?

    private func currentVenueMap() -> VenueMap {
        let ids = fields.fields.map(\.id)
        let centers = fields.fields.map(\.rectangle.center)
        if let cached = venueMapCache, cached.ids == ids, cached.centers == centers {
            return cached.map
        }
        let map = VenueClustering.venueMap(fields: fields.fields)
        venueMapCache = (ids, centers, map)
        return map
    }

    /// The peer-cohort average heatmap for the Compare overlay, filtered to matches that are actually
    /// comparable to `detail`, with an honest caption for whatever cohort was used. Walks a fallback
    /// ladder — same venue + format + window, then same format anywhere in the window, then same
    /// format all-time — and always labels which rung it landed on so the caption never lies about
    /// scope. Nil without a route to compare, or when no comparable match has been played.
    func cohortComparison(for detail: MatchDetailModel, window: CompareWindow) -> CohortComparison? {
        guard let digest = detail.digest, let heat = digest.heat else { return nil }
        let venueMap = currentVenueMap()
        func venue(of id: UUID) -> Int? {
            digestCache.entries[id]?.center.flatMap(venueMap.venue(forCenter:))
        }
        let peers = digests.values.filter { $0.id != digest.id && $0.format == digest.format && $0.heat != nil }
        let recent = peers.filter { window.contains($0.startDate) }

        func build(_ pool: [MatchDigest], scope: CohortComparison.Scope) -> CohortComparison? {
            PortraitHeat.average(pool.compactMap(\.heat)).map {
                CohortComparison(current: Self.landscapeGrid(heat), average: Self.landscapeGrid($0),
                                 count: pool.count, scope: scope, window: window)
            }
        }

        // Rung 1: same venue + format, inside the window — the honest "vs N here" cohort.
        if let here = venue(of: digest.id) {
            let sameVenue = recent.filter { venue(of: $0.id) == here }
            if sameVenue.count >= 3 { return build(sameVenue, scope: .venue) }
        }
        // Rung 2: same format anywhere, still inside the window.
        if recent.count >= 3 { return build(recent, scope: .anyFieldWindowed) }
        // Rung 3 (safety net): same format, all time — the broadest honest baseline.
        return peers.isEmpty ? nil : build(peers, scope: .anyFieldAllTime)
    }

    /// A portrait thumbnail laid on its side, attacking right, as the landscape heatmap views draw it.
    private static func landscapeGrid(_ heat: [Float]) -> HeatmapGrid {
        let columns = PortraitHeat.thumbnailRows, rows = PortraitHeat.thumbnailColumns
        var grid = HeatmapGrid(columns: columns, rows: rows, cells: Array(repeating: 0, count: columns * rows))
        for (index, value) in heat.enumerated() {
            let (portraitRow, portraitColumn) = index.quotientAndRemainder(dividingBy: rows)
            grid.cells[portraitColumn * columns + (columns - 1 - portraitRow)] = Double(value)
        }
        return grid
    }

    /// Average effort of the matches in the last `days`.
    func recentAverageWorkrate(days: Int, excluding excludedID: UUID? = nil) -> Double? {
        season.averageEffort(days: days, asOf: Date(), excluding: excludedID)
    }

    /// The week's load against the usual week's (see `SeasonSummary.loadRatio`).
    func loadRatio(asOf date: Date) -> Double? { season.loadRatio(asOf: date) }

    // MARK: - Editing a match

    /// `date` is kept inside the match. Nil when the match is unknown.
    @discardableResult
    func addEvent(_ kind: MatchEventKind, at date: Date, note: String? = nil, to matchID: UUID) -> MatchEvent? {
        var added: MatchEvent?
        edit(matchID) { record, recorded in
            let event = MatchEvent(kind: kind, date: min(max(date, recorded.start), recorded.end), note: note)
            record.add(event)
            added = event
        }
        return added
    }

    /// Change an event; nil leaves a detail alone, and an empty note clears it.
    func setEvent(_ eventID: UUID, in matchID: UUID, kind: MatchEventKind? = nil, date: Date? = nil, note: String? = nil) {
        edit(matchID) { record, recorded in
            record.setEvent(eventID, kind: kind, date: date.map { min(max($0, recorded.start), recorded.end) }, note: note)
        }
    }

    /// Returns the event, for `restoreEvent` to undo with.
    @discardableResult
    func deleteEvent(_ eventID: UUID, from matchID: UUID) -> MatchEvent? {
        var removed: MatchEvent?
        edit(matchID) { record, _ in removed = record.removeEvent(eventID) }
        return removed
    }

    func restoreEvent(_ event: MatchEvent, to matchID: UUID) {
        edit(matchID) { record, _ in record.add(event) }
    }

    /// Say when the match really started and ended; nil for where the recording did. Nothing
    /// recorded is lost, and `trim(id, start: nil, end: nil)` undoes it.
    func trim(_ matchID: UUID, start: Date?, end: Date?) {
        edit(matchID) { record, _ in
            record.trimmedStart = start
            record.trimmedEnd = end
        }
    }

    func setOpponent(_ opponent: String?, for matchID: UUID) {
        edit(matchID) { record, _ in record.opponent = Self.trimmed(opponent) }
    }

    func setNotes(_ notes: String?, for matchID: UUID) {
        edit(matchID) { record, _ in record.notes = Self.trimmed(notes) }
    }

    /// To turn a pitch around, pass the opposite of `analytics.attackDirection.flipsAttack`.
    func setFlipsAttack(_ flipsAttack: Bool?, for matchID: UUID) {
        edit(matchID) { record, _ in record.flipsAttack = flipsAttack }
    }

    private static func trimmed(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Change a match's record, starting one for a match that has none.
    private func edit(_ matchID: UUID, _ change: (inout MatchRecord, DateInterval) -> Void) {
        guard let summary = matches.first(where: { $0.id == matchID }) else { return }
        // The record may be on disk and not yet attached to a cold-launch row.
        let existing = summary.record ?? Self.decodeRecord(from: AppGroup.matchRecordURL(for: matchID))
        guard existing != nil || summary.workout != nil else { return }
        let recorded = MatchSummary.recordedInterval(workout: summary.workout, record: existing)
        var record = existing ?? MatchRecord(
            id: matchID, startDate: recorded.start, endDate: recorded.end, fieldID: nil, events: [], teamCode: nil,
            format: summary.format == .indoor ? .indoor : nil)
        change(&record, recorded)
        save(record: record)
    }

    // MARK: - Match record persistence

    /// Heal on-disk records whose `id` never matched their synced HKWorkout's uuid (a failed
    /// `finishWorkout()`, an older watch build, or a transfer edge): each such orphan would join
    /// with nothing and surface as a duplicate ghost row next to its workout forever. Pair each
    /// orphan with an *unclaimed* workout (no record under its own uuid) starting within ±3 minutes
    /// whose duration agrees within max(60 s, 10% of the workout's); closest start wins ties.
    /// Adoption rewrites the record file under the workout's uuid and deletes the old one, so the
    /// pass is idempotent — the next refresh finds no orphan to adopt.
    private func adoptOrphanRecords(_ records: [UUID: MatchRecord],
                                    workouts: [HKWorkout],
                                    workoutIDs: Set<UUID>) -> [UUID: MatchRecord] {
        var records = records
        let orphans = records.values.filter { !workoutIDs.contains($0.id) }
        guard !orphans.isEmpty else { return records }

        // The watch writes the match's own id into the workout, so identity beats any guess.
        let workoutsByMatchID = Dictionary(
            workouts.compactMap { workout in
                (workout.metadata?[HKMetadataKeyExternalUUID] as? String)
                    .flatMap(UUID.init(uuidString:)).map { ($0, workout) }
            }, uniquingKeysWith: { first, _ in first })

        for var record in orphans {
            if let workout = workoutsByMatchID[record.id], records[workout.uuid] != nil {
                // A second copy of a match that already has its record.
                try? FileManager.default.removeItem(at: AppGroup.matchRecordURL(for: record.id))
                records.removeValue(forKey: record.id)
                MatchLog.info("dropped duplicate record \(record.id) of workout \(workout.uuid)", category: "matchstore")
                continue
            }
            guard let recordEnd = record.endDate else { continue }
            let recordDuration = recordEnd.timeIntervalSince(record.startDate)
            let candidate = workoutsByMatchID[record.id] ?? workouts
                .filter { records[$0.uuid] == nil }
                .filter { abs($0.startDate.timeIntervalSince(record.startDate)) <= 180 }
                // Start to end, not `duration`: that excludes pauses, and the record doesn't.
                .filter { workout in
                    let span = workout.endDate.timeIntervalSince(workout.startDate)
                    return abs(span - recordDuration) <= max(60, span * 0.1)
                }
                .filter { workout in
                    // Never pair across an explicit indoor/outdoor mismatch.
                    guard let workoutIsIndoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool
                    else { return true }
                    return workoutIsIndoor == (record.format == .indoor)
                }
                .min { abs($0.startDate.timeIntervalSince(record.startDate)) <
                       abs($1.startDate.timeIntervalSince(record.startDate)) }
            guard let workout = candidate else { continue }

            let oldID = record.id
            record.id = workout.uuid
            // Persist under the adopted identity, then remove the mismatched file.
            let encoder = MatchTrackerJSON.encoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(record) {
                try? data.write(to: AppGroup.matchRecordURL(for: record.id), options: .atomic)
                try? FileManager.default.removeItem(at: AppGroup.matchRecordURL(for: oldID))
            }
            records.removeValue(forKey: oldID)
            records[record.id] = record
            // Anything cached under the old id is now stale.
            detailCache.removeValue(forKey: oldID)
            if badgeCache.removeValue(forKey: oldID) != nil {
                schedulePersistBadgeCache()
            }
            MatchLog.info("adopted orphan record \(oldID) into workout \(workout.uuid)",
                          category: "matchstore")
        }
        return records
    }

    func loadRecords() -> [UUID: MatchRecord] {
        Self.loadRecordsFromDisk()
    }

    /// Decode every on-disk match record — hundreds of file reads + JSON decodes (records carry
    /// large `headings` arrays), so this is nonisolated to run off the main actor via Task.detached.
    nonisolated private static func loadRecordsFromDisk() -> [UUID: MatchRecord] {
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
        // Phone-side edits funnel through here (position edits, event tweaks, field binding) —
        // journal what changed shape-wise, never the contents.
        MatchLog.info("user: saved match record \(record.id) (\(record.events.count) events, positions \(record.reportedPositions?.count ?? 0), field \(record.fieldID != nil ? "bound" : "none"))",
                      category: "matchstore")
        let encoder = MatchTrackerJSON.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: AppGroup.matchRecordURL(for: record.id), options: .atomic)

        // The stored badge (position / field) may be stale after an edit — mark it so the row
        // recomputes once from the refreshed detail model, while still seeding instantly.
        if var badge = badgeCache[record.id], badge.stale != true {
            badge.stale = true
            badgeCache[record.id] = badge
            schedulePersistBadgeCache()
        }

        if let index = matches.firstIndex(where: { $0.id == record.id }) {
            let summary = MatchSummary(id: record.id, workout: matches[index].workout, record: record,
                                       cached: matches[index].cached)
            matches[index] = summary
            contentVersion &+= 1
            detailCache[record.id]?.updateRecord(record)
        }
        fillDigests()
    }

    // MARK: - Match deletion

    /// How a delete resolved. Either way the match is gone from the app for good.
    enum DeleteOutcome {
        /// Fully removed, including its HKWorkout (or it never had one).
        case deleted
        /// Removed from MatchTracker, but the HKWorkout couldn't be deleted (HealthKit only lets
        /// an app delete objects it saved itself) — the id is persisted as hidden instead.
        case hiddenOnly
    }

    /// Delete a match everywhere we can: its on-disk record, its HKWorkout (when HealthKit lets
    /// us), and every in-memory / persisted cache entry. Idempotent — deleting an already-gone
    /// match is a harmless no-op pass over the same steps.
    func delete(_ summary: MatchSummary) async -> DeleteOutcome {
        MatchLog.info("deleting match \(summary.id)", category: "matchstore")
        try? FileManager.default.removeItem(at: AppGroup.matchRecordURL(for: summary.id))

        var outcome = DeleteOutcome.deleted
        if let workout = summary.workout {
            do {
                try await healthKit.deleteWorkout(workout)
            } catch {
                MatchLog.error("HealthKit delete failed for \(summary.id) — hiding instead",
                               category: "matchstore")
                outcome = .hiddenOnly
            }
        } else if summary.cached?.hasWorkout == true {
            // Cold-cache row whose HKWorkout hasn't reconciled yet — no handle to delete it with,
            // so hide the id to keep the workout from resurfacing on the next refresh.
            outcome = .hiddenOnly
        }
        if outcome == .hiddenOnly {
            hiddenMatchIDs.insert(summary.id)
            Self.writeHiddenMatchIDs(hiddenMatchIDs)
        }

        matches.removeAll { $0.id == summary.id }
        detailCache.removeValue(forKey: summary.id)
        digestCache.entries[summary.id] = nil
        digests[summary.id] = nil
        schedulePersistDigests()
        if badgeCache.removeValue(forKey: summary.id) != nil {
            schedulePersistBadgeCache()
        }
        contentVersion &+= 1
        schedulePersistSummaries()
        return outcome
    }

    nonisolated private static var hiddenMatchesURL: URL {
        AppGroup.containerURL.appendingPathComponent(hiddenMatchesFileName)
    }

    nonisolated private static func loadHiddenMatchIDs() -> Set<UUID> {
        guard let data = try? Data(contentsOf: hiddenMatchesURL),
              let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data) else { return [] }
        return ids
    }

    /// Written synchronously in `delete` — it's one tiny array, and losing it would resurrect a
    /// deleted match.
    nonisolated private static func writeHiddenMatchIDs(_ ids: Set<UUID>) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: hiddenMatchesURL, options: .atomic)
    }

    // MARK: - Field-edit invalidation

    /// A saved field's geometry changed (a corner edit — from a match's Adjust Field flow or the
    /// Fields tab). The field rectangle is the projection basis for every match that resolves to it,
    /// so the persisted row badges (position / field name) and the in-memory analytics are stale. Without a field → match index we
    /// can't cheaply tell which matches resolve to the edited field, so this clears conservatively:
    /// drop every cached badge (rows recompute lazily on next render) and reproject every cached
    /// detail model. Digests know which fields they were drawn from and refresh themselves.
    func invalidateForFieldChange() {
        venueMapCache = nil
        if !badgeCache.isEmpty {
            // Mark stale rather than clearing: rows keep painting hasRoute/distance (field-
            // independent) instantly and recompute the field-derived parts lazily. Clearing
            // wholesale made every route glyph in a 300-match list blink out after a field edit.
            for (id, badge) in badgeCache where badge.stale != true {
                var marked = badge
                marked.stale = true
                badgeCache[id] = marked
            }
            schedulePersistBadgeCache()
        }
        // Reanalyze incrementally, yielding between models so a big cache never stalls the main
        // actor in one burst. Restarting on re-entry coalesces the repeated invalidations a single
        // field save can fire.
        reanalyzeTask?.cancel()
        let models = Array(detailCache.values)
        reanalyzeTask = Task {
            for model in models {
                guard !Task.isCancelled else { return }
                model.reanalyze()
                await Task.yield()
            }
            fillDigests()
        }
    }

    /// The in-flight incremental reanalysis pass from `invalidateForFieldChange`.
    private var reanalyzeTask: Task<Void, Never>?

    static func decodeRecord(from url: URL) -> MatchRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MatchTrackerJSON.decoder().decode(MatchRecord.self, from: data)
    }
}
