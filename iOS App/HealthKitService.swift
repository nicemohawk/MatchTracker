// HealthKitService.swift
// MatchTracker

import Foundation
import HealthKit
import CoreLocation
import MatchTrackerKit

/// Reads soccer workouts, routes, and heart-rate samples from HealthKit.
/// Authorization mirrors the legacy `MatchesTableViewController` type set.
final class HealthKitService {
    static let shared = HealthKitService()

    let healthStore = HKHealthStore()

    private let readTypes: Set<HKSampleType> = {
        var types: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]
        let identifiers: [HKQuantityTypeIdentifier] = [.activeEnergyBurned, .basalEnergyBurned, .distanceWalkingRunning, .heartRate, .vo2Max]
        for identifier in identifiers {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) { types.insert(type) }
        }
        return types
    }()

    private var shareTypes: Set<HKSampleType> {
        [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
    }

    var isHealthDataAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        guard isHealthDataAvailable else { return }
        try await healthStore.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    // MARK: - Workouts

    /// All `.soccer` workouts, most recent first.
    func fetchSoccerWorkouts() async throws -> [HKWorkout] {
        try await fetchWorkouts(matching: HKQuery.predicateForWorkouts(with: .soccer))
    }

    /// Every match, most recent first: soccer from anyone, and the other sports MatchTracker records
    /// from MatchTracker alone (somebody else's hockey isn't a match it can claim).
    func fetchMatchWorkouts() async throws -> [HKWorkout] {
        let types = SportProfile.all.compactMap { HKWorkoutActivityType(rawValue: $0.workoutActivityTypeRawValue) }
        let anySport = NSCompoundPredicate(orPredicateWithSubpredicates: types.map {
            HKQuery.predicateForWorkouts(with: $0)
        })
        return try await fetchWorkouts(matching: anySport).filter {
            $0.workoutActivityType == .soccer || $0.sourceIdentifier.hasPrefix(WorkoutSpan.ownSourcePrefix)
        }
    }

    private func fetchWorkouts(matching predicate: NSPredicate) async throws -> [HKWorkout] {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (results as? [HKWorkout]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    /// Delete a workout (and its route samples) from HealthKit. Routes go first — they'd be
    /// orphaned otherwise — and their failures are ignored; only the workout delete itself throws.
    /// HealthKit only lets an app delete objects it saved, so this fails for workouts recorded by
    /// another source (callers hide the match instead).
    func deleteWorkout(_ workout: HKWorkout) async throws {
        let routes = (try? await fetchRoutes(for: workout)) ?? []
        if !routes.isEmpty {
            try? await healthStore.delete(routes)
        }
        try await healthStore.delete(workout)
    }

    // MARK: - Route

    /// Track points for a workout, ordered by time. A recording interrupted by a relaunch has more
    /// than one route.
    func fetchTrack(for workout: HKWorkout) async throws -> [TrackPoint] {
        var points: [TrackPoint] = []
        for route in try await fetchRoutes(for: workout) {
            points += try await fetchLocations(for: route).map(Self.trackPoint(from:))
        }
        points.sort { $0.timestamp < $1.timestamp }
        return points.indices
            .filter { $0 == 0 || points[$0].timestamp > points[$0 - 1].timestamp }
            .map { points[$0] }
    }

    private func fetchRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        let predicate = HKQuery.predicateForObjects(from: workout)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (results as? [HKWorkoutRoute]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    private func fetchLocations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            var accumulated: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error { continuation.resume(throwing: error); return }
                if let locations { accumulated.append(contentsOf: locations) }
                if done { continuation.resume(returning: accumulated) }
            }
            healthStore.execute(query)
        }
    }

    static func trackPoint(from location: CLLocation) -> TrackPoint {
        TrackPoint(
            coordinate: Coordinate2D(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            ),
            timestamp: location.timestamp,
            speedMetersPerSecond: location.speed >= 0 ? location.speed : -1,
            courseDegrees: location.course >= 0 ? location.course : -1,
            horizontalAccuracy: location.horizontalAccuracy
        )
    }

    // MARK: - Heart rate

    /// Time-ordered heart-rate samples (date, bpm) over an interval, for charting.
    func fetchHeartRateSeries(from start: Date, to end: Date) async throws -> [(date: Date, bpm: Double)] {
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let unit = HKUnit.count().unitDivided(by: .minute())

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: heartRateType, predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: [sort]
            ) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                let samples = (results as? [HKQuantitySample]) ?? []
                continuation.resume(returning: samples.map { ($0.startDate, $0.quantity.doubleValue(for: unit)) })
            }
            healthStore.execute(query)
        }
    }
}

// MARK: - One match's samples

/// Everything HealthKit holds about one match, for its whole recording.
struct MatchSamples: Sendable {
    var track: [TrackPoint]
    var heartRate: [HeartRateSample]
    /// Distance inside the trim. Nil when HealthKit measured none.
    var distanceMeters: Double?
}

extension HealthKitService {
    /// HealthKit can't be read while the phone is locked. It says so with an error that is about
    /// the moment, not the match.
    static func isLocked(_ error: Error) -> Bool {
        (error as? HKError)?.code == .errorDatabaseInaccessible
    }

    /// The workout's route, or the record's redundant copy when that is missing or only the tail of
    /// the match. Throws when the route can't be read and there is no copy: that is not the same as
    /// there being none. Heart rate degrades to none, unless the phone is locked.
    func fetchSamples(for workout: HKWorkout?, record: MatchRecord?, recorded: DateInterval,
                      played: DateInterval) async throws -> MatchSamples {
        async let fetchedHeartRate = fetchHeartRateSeries(from: recorded.start, to: recorded.end)
        async let distance = fetchDistance(of: workout, recorded: recorded, played: played)

        var track: [TrackPoint] = []
        let copy = record?.track ?? []
        if let workout {
            do {
                track = try await fetchTrack(for: workout)
            } catch {
                guard !copy.isEmpty else { throw error }
            }
        }
        if Double(copy.count) > Double(track.count) * 1.1 { track = copy }

        var heartRate: [HeartRateSample] = []
        do {
            heartRate = try await fetchedHeartRate.map { HeartRateSample(date: $0.date, bpm: $0.bpm) }
        } catch where Self.isLocked(error) {
            throw error
        } catch {
            MatchLog.error("heart rate fetch failed: \(error.localizedDescription)", category: "healthkit")
        }
        return MatchSamples(track: track, heartRate: heartRate, distanceMeters: await distance)
    }

    /// The workout's distance: its total, or for a trimmed match what was covered inside the trim.
    func fetchDistance(of workout: HKWorkout?, recorded: DateInterval, played: DateInterval) async -> Double? {
        guard let workout else { return nil }
        let type = HKQuantityType(.distanceWalkingRunning)
        guard played != recorded else {
            return workout.statistics(for: type)?.sumQuantity()?.doubleValue(for: .meter())
        }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: workout),
            HKQuery.predicateForSamples(withStart: played.start, end: played.end)
        ])
        return await withCheckedContinuation { continuation in
            healthStore.execute(HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                  options: .cumulativeSum) { _, statistics, _ in
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: .meter()))
            })
        }
    }
}

extension HKWorkout {
    var sourceIdentifier: String { sourceRevision.source.bundleIdentifier }
}
