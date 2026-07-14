//
//  TrainingLoadService.swift
//  MatchTracker
//

import Foundation
import Observation
import HealthKit

/// Pulls broader-fitness context from HealthKit so a single match's workrate can be read against
/// the player's trend: latest VO2max and a 28-day soccer training load aggregate.
@Observable
@MainActor
final class TrainingLoadService {
    struct FourWeekLoad {
        var workoutCount: Int
        var totalDuration: TimeInterval
        var totalActiveCalories: Double
        var averageWorkrateScore: Double?   // filled by MatchStore when analytics are cached
    }

    private(set) var vo2Max: Double?              // ml/kg/min
    private(set) var vo2MaxDate: Date?
    private(set) var fourWeekLoad: FourWeekLoad?

    @ObservationIgnored private let healthStore = HKHealthStore()

    func refresh() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        await readVO2Max()
        await readFourWeekLoad()
    }

    private func readVO2Max() async {
        let type = HKQuantityType(.vo2Max)
        let sample: HKQuantitySample? = await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                      sortDescriptors: [sort]) { _, results, _ in
                continuation.resume(returning: results?.first as? HKQuantitySample)
            }
            healthStore.execute(query)
        }
        guard let sample else { return }
        let unit = HKUnit(from: "ml/kg*min")
        vo2Max = sample.quantity.doubleValue(for: unit)
        vo2MaxDate = sample.startDate
    }

    private func readFourWeekLoad() async {
        let start = Calendar.current.date(byAdding: .day, value: -28, to: Date()) ?? Date()
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForWorkouts(with: .soccer),
            HKQuery.predicateForSamples(withStart: start, end: nil)
        ])
        let workouts: [HKWorkout] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, _ in
                continuation.resume(returning: (results as? [HKWorkout]) ?? [])
            }
            healthStore.execute(query)
        }
        guard !workouts.isEmpty else {
            fourWeekLoad = nil
            return
        }
        let calories = workouts.reduce(0.0) { total, workout in
            let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .largeCalorie()) ?? 0
            return total + energy
        }
        fourWeekLoad = FourWeekLoad(
            workoutCount: workouts.count,
            totalDuration: workouts.reduce(0) { $0 + $1.duration },
            totalActiveCalories: calories,
            averageWorkrateScore: nil
        )
    }

    /// MatchStore injects the average workrate of analyzed matches in the same window (HealthKit
    /// has no notion of our workrate score).
    func setAverageWorkrate(_ average: Double?) {
        guard fourWeekLoad != nil else { return }
        fourWeekLoad?.averageWorkrateScore = average
    }

    // MARK: - Acute:chronic workload

    /// The sports-science acute:chronic workload ratio (ACWR) — the last 7 days of output measured
    /// against the rolling 28-day norm — the standard flag for under-load and injury-risky spikes.
    /// HealthKit exposes no per-sport ACWR, so we derive it from our own stored workrate history
    /// (the least-invasive correct source): a 7-day acute average over a 28-day chronic average.
    struct AcuteChronicLoad {
        enum Status: String { case balanced, ramping, high }
        var ratio: Double
        var status: Status
    }

    /// Classify a 7-day acute average against a 28-day chronic average. Returns nil when either
    /// window is empty (no cached analytics yet) so callers can show a "building" placeholder
    /// instead of a fabricated ratio. The sweet spot (~0.8–1.3) reads as balanced; a moderate
    /// spike (1.3–1.5) as ramping; anything higher as an elevated-risk high.
    static func acuteChronic(acute: Double?, chronic: Double?) -> AcuteChronicLoad? {
        guard let acute, let chronic, chronic > 0 else { return nil }
        let ratio = acute / chronic
        let status: AcuteChronicLoad.Status
        switch ratio {
        case ..<1.3: status = .balanced
        case ..<1.5: status = .ramping
        default: status = .high
        }
        return AcuteChronicLoad(ratio: ratio, status: status)
    }
}
