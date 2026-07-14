// DemoMatchFactory.swift
// MatchTracker
//
// DEBUG-only synthetic match generator. Produces realistic soccer data that flows through the
// REAL analysis pipeline: an HKWorkout (.soccer, outdoor) with active-energy, heart-rate and
// distance samples, an HKWorkoutRoute of GPS fixes, and a MatchRecord written to the app group
// exactly where a watch transfer would land it. Nothing here ships in Release builds.
//
// The whole file is compiled out unless DEBUG is defined.

#if DEBUG
import Foundation
import CoreGraphics
import CoreLocation
import HealthKit
import MatchTrackerKit

/// Deterministic seedable PRNG (SplitMix64). Keyed on `daysAgo` per match so a generated season
/// is fully reproducible — never seeded from `Date.now`.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Builds synthetic-but-plausible matches for testers. `@MainActor` because it touches the
/// main-actor `FieldsModel`; the HealthKit work is `async` and hops off the main queue at each await.
@MainActor
final class DemoMatchFactory {
    /// Knobs that let `generateSeason` spread matches out while `generateMatch` uses fixed defaults.
    struct Plan {
        var seed: UInt64
        var homeXOffset: Double     // shifts the midfielder's home point along the long axis
        var sprintsPerHalf: Int
        var speedScale: Double      // scales base wander speed → varies total distance
        var goalsForUs: Int
        var goalsAgainst: Int
        var myGoals: Int
        var assists: Int
        var flags: Int
    }

    private let healthKit: HealthKitService
    private let fields: FieldsModel
    private let teamCode: String

    // MARK: Fixed demo field (matches scripts/seed-test-backend.sh: 105×68 m, ~39.325,-82.101)

    static let demoFieldID = UUID(uuidString: "DE110000-0000-0000-0000-000000000001")!
    private let fieldCenter = Coordinate2D(latitude: 39.325, longitude: -82.101)
    private let fieldLength = 105.0     // long axis (m)
    private let fieldWidth = 68.0       // short axis (m)
    private let fieldHeading = 80.0     // compass bearing of the long axis (deg)

    // Session timing: two 40-min halves around a 12-min halftime → 92 min total.
    private let firstHalfSeconds = 2400
    private let halftimeSeconds = 720
    private let secondHalfSeconds = 2400
    private var totalSeconds: Int { firstHalfSeconds + halftimeSeconds + secondHalfSeconds }
    private var secondHalfStart: Int { firstHalfSeconds + halftimeSeconds }

    init(healthKit: HealthKitService, fields: FieldsModel, teamCode: String) {
        self.healthKit = healthKit
        self.fields = fields
        self.teamCode = teamCode
    }

    // MARK: - Public API

    /// Generate one sample match `daysAgo` back, returning the HKWorkout UUID (== record id).
    @discardableResult
    func generateMatch(daysAgo: Int) async throws -> UUID {
        let plan = Plan(seed: seed(forDaysAgo: daysAgo),
                        homeXOffset: 0,
                        sprintsPerHalf: 10,
                        speedScale: 1.0,
                        goalsForUs: 2, goalsAgainst: 1, myGoals: 1, assists: 1, flags: 2)
        return try await generate(daysAgo: daysAgo, plan: plan)
    }

    /// Generate a 5-match season (2, 6, 9, 13, 20 days ago). Each match uses a seeded plan so the
    /// comparative heatmap and 4-week training-load average have real spread.
    func generateSeason() async throws {
        for daysAgo in [2, 6, 9, 13, 20] {
            var rng = SplitMix64(seed: seed(forDaysAgo: daysAgo))
            let plan = Plan(
                seed: seed(forDaysAgo: daysAgo),
                homeXOffset: Double.random(in: -0.05...0.05, using: &rng),
                sprintsPerHalf: Int.random(in: 8...12, using: &rng),
                speedScale: Double.random(in: 0.9...1.15, using: &rng),
                goalsForUs: Int.random(in: 0...3, using: &rng),
                goalsAgainst: Int.random(in: 0...3, using: &rng),
                myGoals: Int.random(in: 0...2, using: &rng),
                assists: Int.random(in: 0...2, using: &rng),
                flags: Int.random(in: 1...3, using: &rng)
            )
            _ = try await generate(daysAgo: daysAgo, plan: plan)
        }
    }

    /// Generate one ~60-minute INDOOR session `daysAgo` back, returning the HKWorkout UUID. Indoor
    /// play synthesizes heart-rate + energy only — no GPS route, no field — so the app's HR-only
    /// workrate path and the reduced indoor detail UI are testable without a watch.
    @discardableResult
    func generateIndoorSession(daysAgo: Int) async throws -> UUID {
        var rng = SplitMix64(seed: seed(forDaysAgo: daysAgo) ^ 0x1D00_1D00_1D00_1D00)
        let start = sessionStart(daysAgo: daysAgo)
        let session = synthesizeIndoorSession(start: start, rng: &rng)

        let workout = try await saveWorkout(session: session, indoor: true)
        let record = makeIndoorRecord(workoutID: workout.uuid, session: session)
        try writeRecord(record)

        MatchLog.info("Generated indoor session \(workout.uuid.uuidString.prefix(8)) (\(session.heartRate.count) HR samples)",
                      category: "demo")
        return workout.uuid
    }

    // MARK: - Generation core

    private func seed(forDaysAgo daysAgo: Int) -> UInt64 {
        0x5DEA_DBEE_F000_D1CE ^ (UInt64(bitPattern: Int64(daysAgo)) &* 0x9E37_79B9_7F4A_7C15)
    }

    private func generate(daysAgo: Int, plan: Plan) async throws -> UUID {
        ensureDemoFieldExists()

        var rng = SplitMix64(seed: plan.seed)
        let start = sessionStart(daysAgo: daysAgo)
        let session = synthesizeSession(start: start, plan: plan, rng: &rng)

        // 1. HealthKit workout + samples + route through the real builders.
        let workout = try await saveWorkout(session: session)

        // 2. MatchRecord to the app group, keyed by the workout UUID (the join key MatchStore uses).
        let record = makeRecord(workoutID: workout.uuid, session: session, plan: plan, rng: &rng)
        try writeRecord(record)

        MatchLog.info("Generated demo match \(workout.uuid.uuidString.prefix(8)) (\(session.locations.count) fixes)",
                      category: "demo")
        return workout.uuid
    }

    /// Ensure a fixed `FieldModel(source: .trained, name: "Demo Park")` exists, reused by UUID.
    private func ensureDemoFieldExists() {
        guard fields.field(id: Self.demoFieldID) == nil else { return }
        let rectangle = makeRectangle(center: fieldCenter, length: fieldLength,
                                      width: fieldWidth, headingDegrees: fieldHeading)
        let field = FieldModel(
            id: Self.demoFieldID,
            name: "Demo Park",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            outline: rectangle.corners,
            rectangle: rectangle,
            source: .trained,
            observationCount: 1,
            sportID: "soccer"
        )
        fields.save(field, pushToWatch: false)
    }

    private func sessionStart(daysAgo: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = 10
        components.minute = 0
        components.second = 0
        return calendar.date(from: components) ?? day
    }

    // MARK: - Movement model

    /// One fully synthesized session: GPS fixes + the derived HR / energy / distance series and the
    /// sprint intervals (so a "my goal" can be dropped inside a burst).
    private struct Session {
        var start: Date
        var end: Date
        var locations: [CLLocation]
        var heartRate: [(date: Date, bpm: Double)]      // ~1 sample / 10 s
        var energyPerMinute: [Double]                   // kcal, one per session-minute
        var distancePerMinute: [Double]                 // meters, one per session-minute
        var totalDistanceMeters: Double
        var sprintIntervals: [DateInterval]             // second-half bursts, for goalMine placement
        var playWindows: [DateInterval]                 // on-pitch play stretches, for event placement
    }

    /// Simulate a central midfielder at 1 Hz:
    ///  - Ornstein-Uhlenbeck velocity wander mean-reverting toward a home point (attack flips at
    ///    halftime), base walk/jog 0.7–2.6 m/s.
    ///  - 8–12 sprint bursts per half (5–7 s toward random targets at 6–7.5 m/s), acceleration-limited.
    ///  - A 12-min halftime spent ~30 m OUTSIDE the touchline, mostly standing (PeriodDetector break).
    ///  - A ~10-min bench spell ~10 m outside the touchline starting ~20 min into the second half
    ///    (AutoSubDetector emits badged subOut/subIn on reconciliation).
    ///  - HR follows speed with lag (rest ~118, jog ~150, sprint peaks ~185), decays on the bench.
    ///  - horizontalAccuracy jitter 4–12 m.
    private func synthesizeSession(start: Date, plan: Plan, rng: inout SplitMix64) -> Session {
        let halfLength = fieldLength / 2
        let halfWidth = fieldWidth / 2

        // Sprint schedule (absolute session seconds), avoiding warm-up, halftime and the bench spell.
        let benchStart = secondHalfStart + 1200
        let benchEnd = benchStart + 600
        let firstHalfSprints = scheduleSprints(count: plan.sprintsPerHalf, range: 180...(firstHalfSeconds - 120),
                                               avoid: [], rng: &rng)
        let secondHalfSprints = scheduleSprints(count: plan.sprintsPerHalf,
                                                range: (secondHalfStart + 180)...(totalSeconds - 120),
                                                avoid: [benchStart...benchEnd], rng: &rng)
        var sprints = firstHalfSprints + secondHalfSprints
        // Give each sprint a random target in normalized field space.
        var sprintPlans: [(interval: ClosedRange<Int>, targetLong: Double, targetShort: Double)] = []
        for sprint in sprints.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let tx = Double.random(in: 0.1...0.9, using: &rng)
            let ty = Double.random(in: 0.1...0.9, using: &rng)
            sprintPlans.append((sprint, (tx - 0.5) * fieldLength, (ty - 0.5) * fieldWidth))
        }
        sprints = sprintPlans.map { $0.interval }

        // Field-local meters state (long along the long axis, short across).
        var posLong = (0.45 + plan.homeXOffset - 0.5) * fieldLength
        var posShort = 0.0
        var velLong = 0.0
        var velShort = 0.0
        var heartRate = 118.0

        var locations: [CLLocation] = []
        var heartRateSeries: [(date: Date, bpm: Double)] = []
        var perSecondEnergyRaw: [Double] = []
        var perSecondDistance: [Double] = []
        locations.reserveCapacity(totalSeconds)

        for t in 0..<totalSeconds {
            let inHalftime = t >= firstHalfSeconds && t < secondHalfStart
            let onBench = t >= benchStart && t < benchEnd
            let isSecondHalf = t >= secondHalfStart
            let homeLong = ((isSecondHalf ? 0.55 : 0.45) + plan.homeXOffset - 0.5) * fieldLength

            // Desired velocity for this second, by mode.
            var desiredLong = 0.0
            var desiredShort = 0.0
            var maxAccel = 3.0

            if inHalftime {
                // Walk out ~30 m past the touchline, stand, then walk back on just before kickoff.
                let walkingBack = t >= secondHalfStart - 60
                let targetLong = walkingBack ? homeLong : 0.0
                let targetShort = walkingBack ? 0.0 : halfWidth + 30
                (desiredLong, desiredShort) = walkToward(posLong, posShort, targetLong, targetShort,
                                                         walkSpeed: 1.2, rng: &rng)
                maxAccel = 1.5
            } else if onBench {
                // Sit ~10 m outside the touchline (badged auto sub-out/in on reconciliation).
                (desiredLong, desiredShort) = walkToward(posLong, posShort, homeLong, halfWidth + 10,
                                                         walkSpeed: 1.1, rng: &rng)
                maxAccel = 1.5
            } else if let plan = sprintPlans.first(where: { $0.interval.contains(t) }) {
                // Explosive burst toward the sprint target.
                let dl = plan.targetLong - posLong
                let ds = plan.targetShort - posShort
                let mag = max(hypot(dl, ds), 0.001)
                let sprintSpeed = Double.random(in: 6.0...7.5, using: &rng)
                desiredLong = dl / mag * sprintSpeed
                desiredShort = ds / mag * sprintSpeed
                maxAccel = 4.5
            } else {
                // OU wander with a gentle pull back toward the home point.
                let theta = 0.25, pull = 0.02, sigma = 0.9 * plan.speedScale
                velLong += -theta * velLong + pull * (homeLong - posLong) + sigma * nextGaussian(&rng)
                velShort += -theta * velShort + pull * (0 - posShort) + sigma * nextGaussian(&rng)
                let speed = hypot(velLong, velShort)
                let maxBase = 2.6 * plan.speedScale
                if speed > maxBase { velLong *= maxBase / speed; velShort *= maxBase / speed }
                desiredLong = velLong
                desiredShort = velShort
                maxAccel = 3.0
            }

            // Acceleration-limited approach to the desired velocity (plausible accelerations).
            if inHalftime || onBench || sprintPlans.contains(where: { $0.interval.contains(t) }) {
                var dLong = desiredLong - velLong
                var dShort = desiredShort - velShort
                let dMag = hypot(dLong, dShort)
                if dMag > maxAccel { dLong *= maxAccel / dMag; dShort *= maxAccel / dMag }
                velLong += dLong
                velShort += dShort
            }
            // (OU branch already updated velLong/velShort directly.)

            // Integrate position (1 s step).
            let previousLong = posLong
            let previousShort = posShort
            posLong += velLong
            posShort += velShort

            // Keep normal play inside the touchlines; halftime/bench are meant to be outside.
            if !inHalftime && !onBench {
                posLong = clamp(posLong, -halfLength + 1.5, halfLength - 1.5)
                posShort = clamp(posShort, -halfWidth + 1.5, halfWidth - 1.5)
            }

            let stepLong = posLong - previousLong
            let stepShort = posShort - previousShort
            let stepDistance = hypot(stepLong, stepShort)
            let speed = stepDistance   // over a 1 s step, displacement == speed

            // Heart rate follows speed with lag; decays toward rest on the bench / at halftime.
            let hrTarget = (inHalftime || onBench) ? 118.0 : min(190.0, 118.0 + 9.5 * speed)
            heartRate += (hrTarget - heartRate) * 0.05
            heartRate = clamp(heartRate, 95, 195)

            let timestamp = start.addingTimeInterval(TimeInterval(t))
            let coordinate = coordinate(long: posLong, short: posShort)
            let course = courseDegrees(long: stepLong, short: stepShort)
            let accuracy = Double.random(in: 4...12, using: &rng)
            locations.append(CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                altitude: 220,
                horizontalAccuracy: accuracy,
                verticalAccuracy: 6,
                course: course,
                speed: speed,
                timestamp: timestamp
            ))

            if t % 10 == 0 {
                heartRateSeries.append((timestamp, heartRate.rounded()))
            }
            perSecondEnergyRaw.append(0.06 + speed * 0.14)
            perSecondDistance.append(stepDistance)
        }

        // Aggregate per-minute energy (scaled to ~950 kcal total) and distance.
        let minutes = (totalSeconds + 59) / 60
        var energyPerMinute = [Double](repeating: 0, count: minutes)
        var distancePerMinute = [Double](repeating: 0, count: minutes)
        for t in 0..<totalSeconds {
            energyPerMinute[t / 60] += perSecondEnergyRaw[t]
            distancePerMinute[t / 60] += perSecondDistance[t]
        }
        let rawTotal = energyPerMinute.reduce(0, +)
        let energyScale = rawTotal > 0 ? 950.0 / rawTotal : 0
        energyPerMinute = energyPerMinute.map { $0 * energyScale }

        // Play windows (on-pitch stretches) for placing manual events realistically.
        let playWindows = [
            DateInterval(start: start.addingTimeInterval(60), end: start.addingTimeInterval(TimeInterval(firstHalfSeconds - 60))),
            DateInterval(start: start.addingTimeInterval(TimeInterval(secondHalfStart + 60)), end: start.addingTimeInterval(TimeInterval(benchStart - 30))),
            DateInterval(start: start.addingTimeInterval(TimeInterval(benchEnd + 60)), end: start.addingTimeInterval(TimeInterval(totalSeconds - 60)))
        ]

        let sprintIntervals = sprints
            .filter { $0.lowerBound >= secondHalfStart }
            .map { DateInterval(start: start.addingTimeInterval(TimeInterval($0.lowerBound)),
                                end: start.addingTimeInterval(TimeInterval($0.upperBound))) }

        return Session(
            start: start,
            end: start.addingTimeInterval(TimeInterval(totalSeconds)),
            locations: locations,
            heartRate: heartRateSeries,
            energyPerMinute: energyPerMinute,
            distancePerMinute: distancePerMinute,
            totalDistanceMeters: perSecondDistance.reduce(0, +),
            sprintIntervals: sprintIntervals,
            playWindows: playWindows
        )
    }

    /// Synthesize a ~60-minute indoor session as heart rate + energy only (no locations). Interval
    /// structure: a 5-min warm-up ramp, then repeating 6-min blocks of 4-min work / 2-min recovery,
    /// with heart rate lagging the target and energy tracking intensity. Deterministic in `rng`.
    private func synthesizeIndoorSession(start: Date, rng: inout SplitMix64) -> Session {
        let totalSeconds = 3600
        let warmupSeconds = 300
        let blockSeconds = 360      // 6-min block
        let workSeconds = 240       // 4-min work within each block

        var heartRate = 115.0
        var heartRateSeries: [(date: Date, bpm: Double)] = []
        var perSecondEnergyRaw: [Double] = []
        perSecondEnergyRaw.reserveCapacity(totalSeconds)

        for t in 0..<totalSeconds {
            let hrTarget: Double
            if t < warmupSeconds {
                hrTarget = 110 + Double(t) / Double(warmupSeconds) * 45     // ramp 110 → 155
            } else {
                let working = (t - warmupSeconds) % blockSeconds < workSeconds
                hrTarget = (working ? 174.0 : 133.0) + nextGaussian(&rng) * 4
            }
            heartRate += (hrTarget - heartRate) * 0.04
            heartRate = clamp(heartRate, 95, 195)

            let timestamp = start.addingTimeInterval(TimeInterval(t))
            if t % 10 == 0 { heartRateSeries.append((timestamp, heartRate.rounded())) }
            // Energy tracks %heart-rate-reserve intensity (rest 60, reserve 130).
            let intensity = max(0, (heartRate - 60) / 130)
            perSecondEnergyRaw.append(0.05 + intensity * 0.30)
        }

        // Aggregate per-minute energy (scaled to ~650 kcal). Distance stays zero (no route) but is
        // sized to match so `quantitySamples` can index both arrays; zero-meter minutes emit nothing.
        let minutes = (totalSeconds + 59) / 60
        var energyPerMinute = [Double](repeating: 0, count: minutes)
        for t in 0..<totalSeconds { energyPerMinute[t / 60] += perSecondEnergyRaw[t] }
        let rawTotal = energyPerMinute.reduce(0, +)
        let energyScale = rawTotal > 0 ? 650.0 / rawTotal : 0
        energyPerMinute = energyPerMinute.map { $0 * energyScale }
        let distancePerMinute = [Double](repeating: 0, count: minutes)

        // On-pitch play window: whole session minus a short warm-up/cool-down margin.
        let playWindows = [DateInterval(start: start.addingTimeInterval(TimeInterval(warmupSeconds)),
                                        end: start.addingTimeInterval(TimeInterval(totalSeconds - 30)))]

        return Session(
            start: start,
            end: start.addingTimeInterval(TimeInterval(totalSeconds)),
            locations: [],
            heartRate: heartRateSeries,
            energyPerMinute: energyPerMinute,
            distancePerMinute: distancePerMinute,
            totalDistanceMeters: 0,
            sprintIntervals: [],
            playWindows: playWindows
        )
    }

    /// Non-overlapping sprint start windows within `range`, each 5–7 s long, avoiding `avoid` bands.
    private func scheduleSprints(count: Int, range: ClosedRange<Int>,
                                 avoid: [ClosedRange<Int>], rng: inout SplitMix64) -> [ClosedRange<Int>] {
        var chosen: [ClosedRange<Int>] = []
        var attempts = 0
        while chosen.count < count && attempts < count * 20 {
            attempts += 1
            let startSecond = Int.random(in: range.lowerBound...max(range.lowerBound, range.upperBound - 7), using: &rng)
            let duration = Int.random(in: 5...7, using: &rng)
            let interval = startSecond...(startSecond + duration)
            if avoid.contains(where: { $0.overlaps(interval) }) { continue }
            if chosen.contains(where: { $0.overlaps(interval.lowerBound - 40...interval.upperBound + 40) }) { continue }
            chosen.append(interval)
        }
        return chosen
    }

    /// Walk toward a target: move at `walkSpeed` while far, settle into a tiny jitter (<0.3 m/s) once
    /// there (so the wearer reads as "standing" for the period/sub signals).
    private func walkToward(_ posLong: Double, _ posShort: Double, _ targetLong: Double, _ targetShort: Double,
                            walkSpeed: Double, rng: inout SplitMix64) -> (Double, Double) {
        let dl = targetLong - posLong
        let ds = targetShort - posShort
        let distance = hypot(dl, ds)
        if distance > 2 {
            return (dl / distance * walkSpeed, ds / distance * walkSpeed)
        }
        return (nextGaussian(&rng) * 0.12, nextGaussian(&rng) * 0.12)
    }

    // MARK: - HealthKit save

    private func saveWorkout(session: Session, indoor: Bool = false) async throws -> HKWorkout {
        try await requestWriteAuthorization()

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .soccer
        configuration.locationType = indoor ? .indoor : .outdoor

        let builder = HKWorkoutBuilder(healthStore: healthKit.healthStore,
                                       configuration: configuration, device: .local())
        try await builder.beginCollection(at: session.start)
        try await addSamples(quantitySamples(for: session), to: builder)
        try await builder.endCollection(at: session.end)

        guard let workout = try await builder.finishWorkout() else {
            throw DemoError.workoutFinishFailed
        }

        // Attach the GPS route (chunked so a large fix count stays under insert limits). Indoor
        // sessions have no fixes, so there's no route to build.
        guard !session.locations.isEmpty else { return workout }
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthKit.healthStore, device: .local())
        for chunk in stride(from: 0, to: session.locations.count, by: 250) {
            let slice = Array(session.locations[chunk..<min(chunk + 250, session.locations.count)])
            try await routeBuilder.insertRouteData(slice)
        }
        _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)

        return workout
    }

    /// The demo writes energy + HR + distance, which the base `HealthKitService` share set omits;
    /// request those share types here (read set mirrors the service).
    private func requestWriteAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw DemoError.healthDataUnavailable }
        let share: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute(),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.heartRate),
            HKQuantityType(.distanceWalkingRunning)
        ]
        try await healthKit.healthStore.requestAuthorization(toShare: share, read: share)
    }

    /// Bridges the completion-based `HKWorkoutBuilder.add(_:completion:)` to async (its async
    /// overload doesn't resolve cleanly here).
    private func addSamples(_ samples: [HKSample], to builder: HKWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.add(samples) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func quantitySamples(for session: Session) -> [HKSample] {
        var samples: [HKSample] = []

        let heartRateType = HKQuantityType(.heartRate)
        let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
        for sample in session.heartRate {
            samples.append(HKQuantitySample(
                type: heartRateType,
                quantity: HKQuantity(unit: heartRateUnit, doubleValue: sample.bpm),
                start: sample.date, end: sample.date
            ))
        }

        let energyType = HKQuantityType(.activeEnergyBurned)
        let distanceType = HKQuantityType(.distanceWalkingRunning)
        for minute in session.energyPerMinute.indices {
            let minuteStart = session.start.addingTimeInterval(TimeInterval(minute * 60))
            let minuteEnd = min(session.end, minuteStart.addingTimeInterval(60))
            guard minuteEnd > minuteStart else { continue }
            let kcal = session.energyPerMinute[minute]
            if kcal > 0 {
                samples.append(HKQuantitySample(
                    type: energyType,
                    quantity: HKQuantity(unit: .largeCalorie(), doubleValue: kcal),
                    start: minuteStart, end: minuteEnd
                ))
            }
            let meters = session.distancePerMinute[minute]
            if meters > 0 {
                samples.append(HKQuantitySample(
                    type: distanceType,
                    quantity: HKQuantity(unit: .meter(), doubleValue: meters),
                    start: minuteStart, end: minuteEnd
                ))
            }
        }
        return samples
    }

    // MARK: - MatchRecord

    /// Build the record with only MANUAL events (matchStart/End, goals, assist, flags). No period or
    /// sub events — the app's auto-detection is what we want testers to see fire on this data.
    private func makeRecord(workoutID: UUID, session: Session, plan: Plan, rng: inout SplitMix64) -> MatchRecord {
        var events: [MatchEvent] = [
            MatchEvent(kind: .matchStart, date: session.start, source: .manual),
            MatchEvent(kind: .matchEnd, date: session.end, source: .manual)
        ]

        for _ in 0..<plan.goalsForUs {
            events.append(MatchEvent(kind: .goalForUs, date: randomPlayDate(session, &rng), source: .manual))
        }
        for _ in 0..<plan.goalsAgainst {
            events.append(MatchEvent(kind: .goalAgainstUs, date: randomPlayDate(session, &rng), source: .manual))
        }
        // "My goal" lands inside a real second-half sprint burst when one exists.
        for _ in 0..<plan.myGoals {
            let date: Date
            if let sprint = session.sprintIntervals.randomElement(using: &rng) {
                date = sprint.start.addingTimeInterval(sprint.duration / 2)
            } else {
                date = randomPlayDate(session, &rng)
            }
            events.append(MatchEvent(kind: .goalMine, date: date, note: "Sprint finish", source: .manual))
        }
        for _ in 0..<plan.assists {
            events.append(MatchEvent(kind: .assist, date: randomPlayDate(session, &rng), source: .manual))
        }
        for _ in 0..<plan.flags {
            events.append(MatchEvent(kind: .flag, date: randomPlayDate(session, &rng),
                                     note: "Notable moment", source: .manual))
        }

        events.sort { $0.date < $1.date }

        return MatchRecord(
            id: workoutID,
            startDate: session.start,
            endDate: session.end,
            fieldID: Self.demoFieldID,
            events: events,
            teamCode: teamCode,
            sportID: "soccer",
            format: .match          // full-size pitch
        )
    }

    /// Build the indoor record: matchStart/End only, `format: .indoor`, and no field — the app scores
    /// it from heart rate and renders the reduced indoor detail UI.
    private func makeIndoorRecord(workoutID: UUID, session: Session) -> MatchRecord {
        let events: [MatchEvent] = [
            MatchEvent(kind: .matchStart, date: session.start, source: .manual),
            MatchEvent(kind: .matchEnd, date: session.end, source: .manual)
        ]
        return MatchRecord(
            id: workoutID,
            startDate: session.start,
            endDate: session.end,
            fieldID: nil,
            events: events,
            teamCode: teamCode,
            sportID: "soccer",
            format: .indoor
        )
    }

    private func writeRecord(_ record: MatchRecord) throws {
        let encoder = MatchTrackerJSON.encoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: AppGroup.matchRecordURL(for: record.id), options: .atomic)
    }

    private func randomPlayDate(_ session: Session, _ rng: inout SplitMix64) -> Date {
        guard let window = session.playWindows.randomElement(using: &rng), window.duration > 0 else {
            return session.start.addingTimeInterval(session.end.timeIntervalSince(session.start) / 2)
        }
        return window.start.addingTimeInterval(Double.random(in: 0...window.duration, using: &rng))
    }

    // MARK: - Field geometry helpers (mirror the Kit's makeOrientedRectangle via public ENUFrame)

    private func makeRectangle(center: Coordinate2D, length: Double, width: Double,
                               headingDegrees: Double) -> OrientedRectangle {
        let radians = headingDegrees * .pi / 180
        let frame = ENUFrame(reference: center)
        let longAxis = (east: sin(radians), north: cos(radians))
        let shortAxis = (east: cos(radians), north: -sin(radians))
        let halfLength = length / 2
        let halfWidth = width / 2

        func corner(_ alongLong: Double, _ alongShort: Double) -> Coordinate2D {
            let east = alongLong * longAxis.east + alongShort * shortAxis.east
            let north = alongLong * longAxis.north + alongShort * shortAxis.north
            return frame.unproject(CGPoint(x: east, y: north))
        }
        let corners = [
            corner(-halfLength, -halfWidth), corner(halfLength, -halfWidth),
            corner(halfLength, halfWidth), corner(-halfLength, halfWidth)
        ]
        return OrientedRectangle(center: center, lengthMeters: length, widthMeters: width,
                                 headingDegrees: headingDegrees, corners: corners)
    }

    /// Field-local (long, short) meters → geographic coordinate, using the demo field's axes.
    private func coordinate(long: Double, short: Double) -> Coordinate2D {
        let radians = fieldHeading * .pi / 180
        let frame = ENUFrame(reference: fieldCenter)
        let east = long * sin(radians) + short * cos(radians)
        let north = long * cos(radians) + short * -sin(radians)
        return frame.unproject(CGPoint(x: east, y: north))
    }

    /// Compass course of a field-local step vector, or -1 when effectively stationary.
    private func courseDegrees(long: Double, short: Double) -> Double {
        guard hypot(long, short) > 0.05 else { return -1 }
        let radians = fieldHeading * .pi / 180
        let east = long * sin(radians) + short * cos(radians)
        let north = long * cos(radians) + short * -sin(radians)
        var degrees = atan2(east, north) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    enum DemoError: LocalizedError {
        case healthDataUnavailable
        case workoutFinishFailed

        var errorDescription: String? {
            switch self {
            case .healthDataUnavailable: return "HealthKit is unavailable on this device."
            case .workoutFinishFailed: return "Couldn't finish the synthetic workout."
            }
        }
    }
}

/// Standard-normal sample via Box–Muller, using the supplied deterministic generator.
private func nextGaussian(_ rng: inout SplitMix64) -> Double {
    let u1 = Double.random(in: 1e-9...1, using: &rng)
    let u2 = Double.random(in: 0...1, using: &rng)
    return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
}

private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(max(value, lower), upper)
}
#endif
