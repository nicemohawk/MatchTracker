// MatchStore.swift
// MatchTracker

import Foundation
import HealthKit
import MatchTrackerKit

/// One row in the Matches list: an HK soccer workout joined with its received `MatchRecord`.
/// `workout` is nil for "orphan" record-only matches whose HKWorkout couldn't be fetched
/// (e.g. the route/workout never synced from the watch) — those still appear from the record.
struct MatchSummary: Identifiable {
    let id: UUID
    let workout: HKWorkout?
    let record: MatchRecord?

    var startDate: Date { workout?.startDate ?? record?.startDate ?? .distantPast }

    var duration: TimeInterval {
        if let workout { return workout.duration }
        if let record, let end = record.endDate { return end.timeIntervalSince(record.startDate) }
        return 0
    }

    var distanceMeters: Double {
        workout?.statistics(for: HKQuantityType(.distanceWalkingRunning))?
            .sumQuantity()?.doubleValue(for: .meter()) ?? 0
    }
}

/// Loads soccer workouts from HealthKit, joins them with received match records, and vends
/// cached `MatchDetailModel`s carrying lazily computed analytics.
@MainActor
final class MatchStore: ObservableObject {
    @Published private(set) var matches: [MatchSummary] = []
    @Published private(set) var isLoading = false
    @Published var loadError: String?

    let healthKit: HealthKitService
    let fields: FieldsModel

    private var detailCache: [UUID: MatchDetailModel] = [:]

    /// Invoked with newly seen workout UUIDs so the app can auto-upload them.
    var onNewMatches: (([MatchSummary]) -> Void)?

    init(healthKit: HealthKitService = .shared, fields: FieldsModel) {
        self.healthKit = healthKit
        self.fields = fields
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            try await healthKit.requestAuthorization()
            let workouts = try await healthKit.fetchSoccerWorkouts()
            let records = loadRecords()
            let previousIDs = Set(matches.map(\.id))

            let workoutSummaries = workouts.map { workout in
                MatchSummary(id: workout.uuid, workout: workout, record: records[workout.uuid])
            }
            // Records with no matching HK workout still surface as record-only matches.
            let workoutIDs = Set(workouts.map(\.uuid))
            let orphanSummaries = records.values
                .filter { !workoutIDs.contains($0.id) }
                .map { MatchSummary(id: $0.id, workout: nil, record: $0) }

            matches = (workoutSummaries + orphanSummaries).sorted { $0.startDate > $1.startDate }

            let newlyArrived = matches.filter { !previousIDs.contains($0.id) && $0.record != nil }
            if !previousIDs.isEmpty || !newlyArrived.isEmpty {
                onNewMatches?(newlyArrived)
            }
        } catch {
            loadError = error.localizedDescription
        }
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

    /// Heatmaps of every OTHER analyzed match (cached details only — never triggers loads).
    /// Used for the season-average comparison overlay.
    func cachedHeatmaps(excluding id: UUID) -> [HeatmapGrid] {
        detailCache
            .filter { $0.key != id }
            .compactMap { $0.value.analytics?.heatmap }
    }

    /// Average workrate score across matches analyzed in the last `days`, for training-load
    /// context. Only already-cached details count — this never triggers HealthKit loads.
    func recentAverageWorkrate(days: Int) -> Double? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let scores = matches
            .filter { $0.startDate >= cutoff }
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

        if let index = matches.firstIndex(where: { $0.id == record.id }) {
            let summary = MatchSummary(id: record.id, workout: matches[index].workout, record: record)
            matches[index] = summary
            detailCache[record.id]?.updateRecord(record)
        }
    }

    static func decodeRecord(from url: URL) -> MatchRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MatchTrackerJSON.decoder().decode(MatchRecord.self, from: data)
    }
}
