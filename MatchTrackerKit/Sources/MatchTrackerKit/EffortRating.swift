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
        let related = HKQuery.predicateForWorkoutEffortSamplesRelated(workout: workout, activity: nil)
        let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: related)],
                                            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)], limit: 1)
        return try? await query.result(for: store).first.map { Int($0.quantity.doubleValue(for: .appleEffortScore()).rounded()) }
    }

    /// Asks for permission the first time, which is the only time it has a reason to.
    public static func rate(_ workout: HKWorkout, _ score: Int, in store: HKHealthStore) async throws {
        try await store.requestAuthorization(toShare: [type], read: [type])
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: Double(score)),
                                      start: workout.startDate, end: workout.endDate)
        _ = try await store.relateWorkoutEffortSample(sample, with: workout, activity: nil)
    }
}
