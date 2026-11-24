// MatchStore.swift
// MatchTracker

import UIKit
import HealthKit
import MatchTrackerKit
#if canImport(os)
import os
#endif

/// The minimum a Matches-list row needs to render its top-line numbers (date, duration, distance)
/// with NO HealthKit round-trip. Persisted once per refresh so a cold launch paints the last-known
/// list synchronously from disk, before the anchored HK workout query has returned. Everything else
/// a row shows — field name, heat, position — comes from the digests; score / format /
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
    /// Monotonic version of the list's inputs: bumped on any `matches` mutation. The
    /// Matches list keys its precompute rebuild on this instead of
    /// hashing every match id per body evaluation.
    @Published private(set) var contentVersion = 0

    let healthKit: HealthKitService
    let fields: FieldsModel

    private var detailCache: [UUID: MatchDetailModel] = [:]

    /// Every match's digest, for lists, seasons and comparisons: nothing that reads these has to
    /// open a route. Loaded from disk at launch, filled and refreshed in the background.
    @Published private(set) var digests: [UUID: MatchDigest] = [:] {
        didSet {
            digestRevision &+= 1
            publishSurfaces()
        }
    }
    /// Changes whenever any digest does, for lists that rebuild only then.
    private(set) var digestRevision = 0
    private var publishTask: Task<Void, Never>?
    /// Saved (or, as nil, deleted) while a refresh was reading the disk, which it must not undo.
    private var changedDuringRefresh: [UUID: MatchRecord?]?
    private var needsAnotherRefresh = false
    /// Matches whose record has been seen before, so each is announced once, whenever it arrives.
    private var knownRecordIDs = (AppGroup.defaults.stringArray(forKey: "knownRecordIDs") ?? []).compactMap(UUID.init(uuidString:))
        .reduce(into: Set<UUID>()) { $0.insert($1) }
    private var digestCache = DigestCache()
    private nonisolated static let digestCacheFileName = "matchDigests.json"
    private var digestLoadTask: Task<Void, Never>?
    private var digestFillTask: Task<Void, Never>?
    private var needsAnotherDigestFill = false
    /// Matches not worth reading again this launch: they failed, or still have no route.
    private var digestsTriedThisLaunch: Set<UUID> = []
    private var protectedDataObserver: NSObjectProtocol?

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
        // immediately. Records and digests decode off the main actor and attach post-paint;
        // `refresh()` then reconciles everything against HealthKit in place. Hidden (deleted)
        // matches are filtered here so a stale snapshot never flashes them back post-delete.
        matches = Self.hydrateFromCache().filter { !hiddenIDs.contains($0.id) }

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
            guard let records = await self?.recordCache.load() else { return }
            self?.attach(records: records)
        }
    }

    /// The init-time record load + attach. `refresh()` awaits it before diffing "newly arrived"
    /// matches, so records already on disk at launch are never mistaken for new arrivals.
    private var initialRecordsAttach: Task<Void, Never>?
    private let recordCache = RecordCache()

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
            .filter { !knownIDs.contains($0.id) && !hiddenMatchIDs.contains($0.id) }
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
        guard !isLoading else {
            needsAnotherRefresh = true
            return
        }
        isLoading = true
        loadError = nil
        changedDuringRefresh = [:]
        defer {
            isLoading = false
            changedDuringRefresh = nil
            if needsAnotherRefresh {
                needsAnotherRefresh = false
                Task { await refresh() }
            }
        }

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
            var workouts = try await healthKit.fetchMatchWorkouts()
            #if DEBUG
            mark("fetchMatchWorkouts (\(workouts.count))", workoutsStart)
            let recordsStart = Date()
            #endif
            var loadedRecords = await recordCache.load()
            #if DEBUG
            mark("loadRecords (\(loadedRecords.count))", recordsStart)
            #endif
            // Let the init-time attach land first so launch-present records never read as new.
            await initialRecordsAttach?.value
            for (id, record) in changedDuringRefresh ?? [:] {
                loadedRecords[id] = record
                if record == nil { workouts.removeAll { $0.uuid == id } }
            }

            let workoutIDs = Set(workouts.map(\.uuid))
            // Heal records whose id never matched their workout's uuid (failed finishWorkout(),
            // older watch builds) so they join instead of ghosting as a duplicate row.
            let records = adoptOrphanRecords(loadedRecords, workouts: workouts, workoutIDs: workoutIDs)

            // Footage filmed during a match is filed under the id the watch gave it at kickoff.
            for workout in workouts {
                if let matchID = (workout.metadata?[HKMetadataKeyExternalUUID] as? String).flatMap(UUID.init(uuidString:)) {
                    SidelineVideoStore.shared.move(from: matchID, to: workout.uuid)
                }
            }

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
            contentVersion &+= 1
            schedulePersistSummaries()
            updateDetailModels()
            // No workouts at all is more likely a permission than a season deleted.
            if !workouts.isEmpty { forgetDigests(except: Set(matches.map(\.id))) }
            fillDigests()

            announceNewRecords()
            #if DEBUG
            mark("total", refreshStart)
            #endif
        } catch {
            loadError = error.localizedDescription
            didCompleteInitialLoad = true
            for model in detailCache.values { model.sourceUnavailable() }
        }
    }

    /// A record is new whenever it first comes, even long after its workout, or while the phone
    /// was locked and nothing could be listed. Everything known when this began counts as old.
    private func announceNewRecords() {
        let fromWatch = matches.filter { $0.record != nil && $0.record?.startedOnPhone != true }
        let arrived = fromWatch.filter { !knownRecordIDs.contains($0.id) }
        guard !arrived.isEmpty else { return }
        let isFirstLook = AppGroup.defaults.stringArray(forKey: "knownRecordIDs") == nil
        knownRecordIDs.formUnion(arrived.map(\.id))
        AppGroup.defaults.set(knownRecordIDs.map(\.uuidString), forKey: "knownRecordIDs")
        // On the update that added this, everything but the last day's was already announced.
        let yesterday = Date().addingTimeInterval(-86_400)
        onNewMatches?(isFirstLook ? arrived.filter { $0.startDate > yesterday } : arrived)
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

    /// Flush any debounced cache writes immediately (skipping the remaining delay) — called when
    /// the app backgrounds so a pending persist isn't lost if the process is killed.
    func flushPendingPersists() {
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

    /// Every match.
    var season: SeasonSummary { SeasonSummary(playedDigests) }

    func season(_ term: SeasonSummary.Term) -> SeasonSummary {
        SeasonSummary(playedDigests.filter { SeasonSummary.Term(containing: $0.startDate) == term })
    }

    /// The seasons there are matches in, newest first.
    var terms: [SeasonSummary.Term] {
        Set(digests.values.map { SeasonSummary.Term(containing: $0.startDate) }).sorted(by: >)
    }

    /// Widgets, Siri and Spotlight follow the digests, once per burst: filling a history changes
    /// them hundreds of times.
    private func publishSurfaces() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            SystemSurfaces.publish(digests: playedDigests)
        }
    }

    /// The most recent match, if any has been read yet.
    var latestDigest: MatchDigest? {
        (playedDigests.isEmpty ? Array(digests.values) : playedDigests).max { $0.startDate < $1.startDate }
    }

    /// Matches worth counting: a recording of a minute or two is someone trying the app.
    var playedDigests: [MatchDigest] { digests.values.filter { $0.secondsOnPitch >= 300 } }

    /// The most interesting true thing about a match. Nil before its digest, or when there's nothing to say.
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
        defer { store(stillTrue(pending)) }
        for summary in stale {
            // An open match keeps its own digest up to date, unless it's still missing its route.
            if detailCache[summary.id]?.digest?.hasRoute == true { continue }
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
                store(stillTrue(pending))
                pending = [:]
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Drops what was edited, deleted or opened since it was computed.
    private func stillTrue(_ entries: [UUID: DigestCache.Entry]) -> [UUID: DigestCache.Entry] {
        let current = Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.filter { id, entry in
            guard let summary = current[id] else { return false }
            return entry.recordStamp == summary.record?.digestStamp ?? "" && detailCache[id]?.digest?.hasRoute != true
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

    func setFinalScore(_ score: FinalScore?, for matchID: UUID) {
        edit(matchID) { record, _ in record.finalScore = score }
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
        if existing == nil { record.startedOnPhone = true }
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
            if let workout = workoutsByMatchID[record.id], let existing = records[workout.uuid] {
                // Another copy of a match that has a record: perhaps only one the phone started.
                let orphanID = record.id
                record = record.keepingEdits(from: existing)
                record.id = workout.uuid
                adopt(record, replacing: orphanID, in: &records)
                MatchLog.info("merged duplicate record \(orphanID) into workout \(workout.uuid)", category: "matchstore")
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
            adopt(record, replacing: oldID, in: &records)
            MatchLog.info("adopted orphan record \(oldID) into workout \(workout.uuid)",
                          category: "matchstore")
        }
        return records
    }

    /// Persist a record under its adopted identity, then let go of the one it had.
    private func adopt(_ record: MatchRecord, replacing oldID: UUID, in records: inout [UUID: MatchRecord]) {
        let encoder = MatchTrackerJSON.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record),
              (try? data.write(to: AppGroup.matchRecordURL(for: record.id), options: .atomic)) != nil else { return }
        try? FileManager.default.removeItem(at: AppGroup.matchRecordURL(for: oldID))
        records.removeValue(forKey: oldID)
        records[record.id] = record
        if knownRecordIDs.contains(oldID) { knownRecordIDs.insert(record.id) }
        SidelineVideoStore.shared.move(from: oldID, to: record.id)
        // Anything cached under the old id is now stale.
        detailCache.removeValue(forKey: oldID)
    }

    func loadRecords() -> [UUID: MatchRecord] {
        RecordCache.readAll()
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
        changedDuringRefresh?[record.id] = .some(record)

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
        changedDuringRefresh?[summary.id] = .some(nil)
        SidelineVideoStore.shared.removeAll(for: summary.id)

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

    /// A saved field's geometry changed (a corner edit from a match or from Fields). Nothing says
    /// which matches resolve to it, so every open match is projected again. Digests know which
    /// fields they were drawn from and refresh themselves.
    func invalidateForFieldChange() {
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

/// Every match record on disk, decoding only the files that changed since last time: a record
/// carries its whole route, and a few hundred take seconds.
private actor RecordCache {
    private var entries: [URL: (modified: Date, record: MatchRecord)] = [:]

    func load() -> [UUID: MatchRecord] {
        let urls = Self.urls()
        let current = Set(urls)
        entries = entries.filter { current.contains($0.key) }
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, entries[url]?.modified == modified { continue }
            entries[url] = Self.read(url).map { (modified ?? .distantPast, $0) }
        }
        return Dictionary(entries.values.map { ($0.record.id, $0.record) }, uniquingKeysWith: { first, _ in first })
    }

    nonisolated static func readAll() -> [UUID: MatchRecord] {
        Dictionary(urls().compactMap(read).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private nonisolated static func urls() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: AppGroup.matchesDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    private nonisolated static func read(_ url: URL) -> MatchRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MatchTrackerJSON.decoder().decode(MatchRecord.self, from: data)
    }
}
