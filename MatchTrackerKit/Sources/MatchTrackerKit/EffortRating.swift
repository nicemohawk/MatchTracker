// EffortRating.swift
// MatchTrackerKit

import HealthKit

/// How hard a match felt, on Apple's scale. Health counts it toward Training Load, which soccer
/// otherwise never reaches: Apple estimates effort for only a few sports.
@available(iOS 18.0, watchOS 11.0, macOS 15.0, *)
public enum EffortRating {
    public static let range = 1...10

    /// Apple's word for a score, so ours and Fitness's agree.
    public static func word(for score: Int) -> String {
        switch score {
        case ...3: return "Easy"
        case 4...6: return "Moderate"
        case 7...8: return "Hard"
        default: return "All Out"
        }
    }

    private static var type: HKQuantityType { HKQuantityType(.workoutEffortScore) }

    /// The score the wearer gave this workout, here or in Fitness. Nil when unrated or unreadable.
    public static func score(of workout: HKWorkout, in store: HKHealthStore) async -> Int? {
        try? await samples(of: workout, in: store).first.map { Int($0.quantity.doubleValue(for: .appleEffortScore()).rounded()) }
    }

    private static func samples(of workout: HKWorkout, in store: HKHealthStore) async throws -> [HKQuantitySample] {
        let related = HKQuery.predicateForWorkoutEffortSamplesRelated(workout: workout, activity: nil)
        return try await HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: related)],
                                                 sortDescriptors: [SortDescriptor(\.startDate)]).result(for: store)
    }

    /// Asks for permission the first time, which is the only time it has a reason to.
    public static func rate(_ workout: HKWorkout, _ score: Int, in store: HKHealthStore) async throws {
        try await store.requestAuthorization(toShare: [type], read: [type])
        let earlier = (try? await samples(of: workout, in: store)) ?? []
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: Double(score)),
                                      start: workout.startDate, end: workout.endDate)
        _ = try await store.relateWorkoutEffortSample(sample, with: workout, activity: nil)
        // A second opinion replaces the first. One given in Fitness can only be unrelated.
        for old in earlier {
            _ = try? await store.unrelateWorkoutEffortSample(old, from: workout, activity: nil)
            try? await store.delete(old)
        }
    }
}
