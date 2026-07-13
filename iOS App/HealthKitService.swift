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
        let identifiers: [HKQuantityTypeIdentifier] = [.activeEnergyBurned, .basalEnergyBurned, .distanceWalkingRunning, .heartRate]
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
        let predicate = HKQuery.predicateForWorkouts(with: .soccer)
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

    // MARK: - Route

    /// Track points for a workout, ordered by time, converted from the workout's route.
    func fetchTrack(for workout: HKWorkout) async throws -> [TrackPoint] {
        guard let route = try await fetchRoute(for: workout) else { return [] }
        let locations = try await fetchLocations(for: route)
        return locations
            .sorted { $0.timestamp < $1.timestamp }
            .map(Self.trackPoint(from:))
    }

    private func fetchRoute(for workout: HKWorkout) async throws -> HKWorkoutRoute? {
        let predicate = HKQuery.predicateForObjects(from: workout)
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (results as? [HKWorkoutRoute])?.first)
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

    /// Average and maximum heart rate (bpm) over an interval, if any samples exist.
    func fetchHeartRate(from start: Date, to end: Date) async throws -> (average: Double, maximum: Double)? {
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let unit = HKUnit.count().unitDivided(by: .minute())

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: heartRateType,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .discreteMax]
            ) { _, statistics, error in
                if let error { continuation.resume(throwing: error); return }
                guard let statistics,
                      let average = statistics.averageQuantity()?.doubleValue(for: unit),
                      let maximum = statistics.maximumQuantity()?.doubleValue(for: unit) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (average, maximum))
            }
            healthStore.execute(query)
        }
    }

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
