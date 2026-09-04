import Foundation
import CoreGraphics

// MARK: - Key-run curation
//
// Picks a handful of narratively interesting runs out of the (often ~200) detected segments so
// the UI can highlight a few individually instead of drawing every polyline at once.

/// The kinds of "key run" the UI surfaces, in presentation order.
public enum KeyRunCategory: String, Codable, CaseIterable, Sendable {
    case longest          // greatest distance covered
    case fastestSprint    // highest peak speed among sprints
    case deepestAttack    // greatest displacement toward the attacking end
    case longestRecovery  // greatest displacement back toward own goal
    case lateBurst        // best sprint in the final 15 min of on-pitch time
}

/// One curated run, tagged with the category it best exemplifies. `id == segment.id`.
public struct KeyRun: Identifiable, Sendable {
    public var id: UUID
    public var category: KeyRunCategory
    public var segment: RunSegment

    public init(category: KeyRunCategory, segment: RunSegment) {
        self.id = segment.id
        self.category = category
        self.segment = segment
    }
}

/// The player's season-to-date norms for a run's headline metrics, supplied by the app layer so a
/// run can be judged "unusual for *this* player" rather than only unusual within one match. All
/// values are in the same units as `RunSegment` (meters, m/s). When absent, novelty scoring is
/// simply skipped and the other ingredients still rank the match's runs.
public struct RunBaselines: Codable, Sendable {
    public var meanDistance: Double
    public var stdDistance: Double
    public var meanPeakSpeed: Double
    public var stdPeakSpeed: Double

    public init(meanDistance: Double, stdDistance: Double, meanPeakSpeed: Double, stdPeakSpeed: Double) {
        self.meanDistance = meanDistance
        self.stdDistance = stdDistance
        self.meanPeakSpeed = meanPeakSpeed
        self.stdPeakSpeed = stdPeakSpeed
    }

    /// Convenience for call sites that have no season history yet (reads clearer than a bare `nil`).
    public static let none: RunBaselines? = nil
}

/// One run scored for narrative interestingness. `category` carries the legacy label when the run
/// is a category winner (the existing gates), otherwise nil. `reasons` is always non-empty and
/// ordered best-first, so the UI can show why a run was surfaced. `id == segment.id`.
public struct ScoredRun: Identifiable, Sendable {
    public var id: UUID
    public var segment: RunSegment
    public var category: KeyRunCategory?
    public var score: Double
    public var reasons: [String]

    public init(segment: RunSegment, category: KeyRunCategory?, score: Double, reasons: [String]) {
        self.id = segment.id
        self.segment = segment
        self.category = category
        self.score = score
        self.reasons = reasons
    }
}

public enum KeyRunSelector {

    // MARK: Minimum-quality gates (so trivial jog segments never win a headline slot).

    /// Longest must cover at least this far.
    static let minimumLongestDistanceMeters = 30.0
    /// Attack / recovery runs must net at least this much long-axis displacement.
    static let minimumDirectionalDisplacementMeters = 20.0
    /// "Late" = the final quarter-hour of on-pitch time.
    static let lateWindow: TimeInterval = 15 * 60

    /// Picks at most one run per category. A segment may win only one category (the first, in
    /// `KeyRunCategory.allCases` order, whose best candidate it is); the next-best segment fills a
    /// category whose top pick was already claimed. The returned array is in category order and
    /// omits categories with no qualifying run.
    ///
    /// Attack direction is inferred per period. Periods come from periodStart/periodEnd events when
    /// present, otherwise the match is split into two halves at the midpoint of on-pitch time. For
    /// each period the attacking direction along the field long axis is the direction in which the
    /// player's sprint-segment displacements are biased (sum of each sprint's normalized end-minus-
    /// start x; ≥ 0 → attacking toward +x). Sprints are the cleanest directional signal — they are
    /// almost always purposeful runs toward or away from goal — and falling back to all runs when a
    /// period has no sprints keeps the estimate defined. This requires a projector to resolve the
    /// long axis; when `projector` is nil the direction-aware categories (deepestAttack,
    /// longestRecovery) are omitted and only .longest/.fastestSprint/.lateBurst are returned.
    public static func select(runs: [RunSegment], track: [TrackPoint],
                              projector: FieldProjector?, events: [MatchEvent],
                              matchStart: Date, matchEnd: Date) -> [KeyRun] {
        guard !runs.isEmpty else { return [] }

        let intervals = SubstitutionTracker.playingIntervals(
            events: events, matchStart: matchStart, matchEnd: matchEnd
        )
        let totalOnPitch = intervals.reduce(0) { $0 + $1.duration }

        // Signed long-axis displacement (meters, positive = toward the period's attacking end) for
        // each run; empty when there is no projector.
        let attackDisplacement = directionalDisplacements(
            runs: runs, track: track, projector: projector,
            events: events, intervals: intervals, matchStart: matchStart, matchEnd: matchEnd
        )

        // Gate-filtered candidate lists per category, each sorted best-first.
        var candidates: [KeyRunCategory: [(segment: RunSegment, score: Double)]] = [:]

        candidates[.longest] = runs
            .filter { $0.distanceMeters >= minimumLongestDistanceMeters }
            .map { ($0, $0.distanceMeters) }
            .sorted { $0.1 > $1.1 }

        candidates[.fastestSprint] = runs
            .filter { $0.intensity == .sprint }
            .map { ($0, $0.peakSpeed) }
            .sorted { $0.1 > $1.1 }

        candidates[.lateBurst] = runs
            .filter { $0.intensity == .sprint && totalOnPitch > 0
                && onPitchDuration(intervals, from: $0.interval.start) <= lateWindow }
            .map { ($0, $0.peakSpeed) }
            .sorted { $0.1 > $1.1 }

        if projector != nil {
            candidates[.deepestAttack] = runs
                .compactMap { run -> (RunSegment, Double)? in
                    guard let displacement = attackDisplacement[run.id],
                          displacement >= minimumDirectionalDisplacementMeters else { return nil }
                    return (run, displacement)
                }
                .sorted { $0.1 > $1.1 }
            candidates[.longestRecovery] = runs
                .compactMap { run -> (RunSegment, Double)? in
                    guard let displacement = attackDisplacement[run.id],
                          -displacement >= minimumDirectionalDisplacementMeters else { return nil }
                    return (run, -displacement)
                }
                .sorted { $0.1 > $1.1 }
        }

        // Greedy assignment in category order; each segment wins at most one category.
        var used = Set<UUID>()
        var result: [KeyRun] = []
        for category in KeyRunCategory.allCases {
            guard let list = candidates[category] else { continue }
            for candidate in list where !used.contains(candidate.segment.id) {
                used.insert(candidate.segment.id)
                result.append(KeyRun(category: category, segment: candidate.segment))
                break
            }
        }
        return result
    }

    // MARK: - Adaptive interestingness

    // Ingredient weights. Each ingredient is normalized to 0...1 first, so a weight is the most
    // score any single ingredient can add. Event linkage is the strongest signal — a run that
    // directly precedes a goal is almost always the one worth showing — followed by raw magnitude.
    static let magnitudeWeight = 1.0        // biggest distance / top speed within THIS match
    static let eventLinkageWeight = 1.6     // ran into a goal / assist / flag, or answered a concession
    static let noveltyWeight = 0.9          // unusual versus the player's season baselines
    static let directionWeight = 0.7        // meaningful deep attack or long recovery displacement
    static let lateWeight = 0.5             // strong output in the final on-pitch minutes

    /// A positive run must end within this window *before* a positive event to count as feeding it.
    static let preEventWindow: TimeInterval = 20
    /// A run must start within this window *after* conceding to count as a "response run".
    static let responseWindow: TimeInterval = 30
    /// Response-run linkage strength (between a flag and our-goal in importance).
    static let responseEventStrength = 0.6
    /// Novelty z-scores are clamped here before normalizing, so one freak run can't dominate.
    static let noveltyZCap = 3.0

    /// Fraction of a candidate's own score removed per unit of similarity to an already-picked run.
    /// At full similarity (1.0) a near-duplicate loses this share of its score, so diverse runners-up
    /// overtake it. Penalties accumulate across picks.
    static let diversityPenaltyStrength = 0.7
    /// Picks below this (post-penalty) score are dropped, so a quiet match returns fewer than `limit`.
    static let minimumInterestingness = 0.15
    /// Similarity buckets: time (evenly across the match), spatial start cell (6×4), direction sign.
    static let diversityTimeBuckets = 8
    static let diversityGridColumns = 6
    static let diversityGridRows = 4

    // Similarity sub-weights (sum to 1.0 so the combined similarity stays in 0...1).
    static let similarityTimeWeight = 0.30
    static let similarityCategoryWeight = 0.25
    static let similaritySpatialWeight = 0.30
    static let similarityDirectionWeight = 0.15

    /// Scores every run for interestingness and returns the `limit` most interesting *and diverse*
    /// runs, best-first. Ingredients: magnitude (distance/peak percentile within this match), event
    /// linkage (feeding a goal/assist/flag, or answering a concession), novelty versus the player's
    /// season `baselines`, late-match output, and directional meaning (deep attack / long recovery).
    /// Selection is greedy max-score with a similarity penalty so the picks span the match's variety
    /// rather than repeating one motif, and a minimum-interestingness gate returns fewer runs for a
    /// quiet match instead of padding with filler. Deterministic: no randomness, stable tie-breaks.
    public static func scoredSelection(runs: [RunSegment], track: [TrackPoint],
                                       projector: FieldProjector?, events: [MatchEvent],
                                       matchStart: Date, matchEnd: Date,
                                       baselines: RunBaselines?, limit: Int = 6) -> [ScoredRun] {
        guard !runs.isEmpty, limit > 0 else { return [] }

        let intervals = SubstitutionTracker.playingIntervals(
            events: events, matchStart: matchStart, matchEnd: matchEnd
        )
        let totalOnPitch = intervals.reduce(0) { $0 + $1.duration }
        let attackDisplacement = directionalDisplacements(
            runs: runs, track: track, projector: projector,
            events: events, intervals: intervals, matchStart: matchStart, matchEnd: matchEnd
        )
        let fieldLength = projector?.lengthMeters ?? 0

        // Legacy category winners reused verbatim, so labels honor the existing gates exactly.
        let categoryByID: [UUID: KeyRunCategory] = Dictionary(
            select(runs: runs, track: track, projector: projector, events: events,
                   matchStart: matchStart, matchEnd: matchEnd)
                .map { ($0.segment.id, $0.category) },
            uniquingKeysWith: { first, _ in first }
        )

        // Percentile references for magnitude scoring.
        let sortedDistances = runs.map { $0.distanceMeters }.sorted()
        let sortedPeaks = runs.map { $0.peakSpeed }.sorted()
        let longestID = runs.filter { $0.distanceMeters >= minimumLongestDistanceMeters }
            .max { $0.distanceMeters < $1.distanceMeters }?.id
        let fastestSprintID = runs.filter { $0.intensity == .sprint }
            .max { $0.peakSpeed < $1.peakSpeed }?.id

        let scored = runs.map { run -> ScoredRun in
            score(run: run, categoryByID: categoryByID, sortedDistances: sortedDistances,
                  sortedPeaks: sortedPeaks, longestID: longestID, fastestSprintID: fastestSprintID,
                  events: events, baselines: baselines, attackDisplacement: attackDisplacement,
                  fieldLength: fieldLength, intervals: intervals, totalOnPitch: totalOnPitch)
        }

        return diversify(scored, track: track, projector: projector,
                         attackDisplacement: attackDisplacement,
                         matchStart: matchStart, matchEnd: matchEnd, limit: limit)
    }

    // MARK: Per-run scoring

    private static func score(
        run: RunSegment, categoryByID: [UUID: KeyRunCategory],
        sortedDistances: [Double], sortedPeaks: [Double], longestID: UUID?, fastestSprintID: UUID?,
        events: [MatchEvent], baselines: RunBaselines?, attackDisplacement: [UUID: Double],
        fieldLength: Double, intervals: [DateInterval], totalOnPitch: TimeInterval
    ) -> ScoredRun {
        // Each ingredient contributes (addedScore, optional reason); reasons rank by contribution.
        var contributions: [(added: Double, reason: String?)] = []

        // 1. Magnitude within this match.
        let distancePercentile = percentileRank(run.distanceMeters, in: sortedDistances)
        let peakPercentile = percentileRank(run.peakSpeed, in: sortedPeaks)
        let magnitude = max(distancePercentile, peakPercentile)
        var magnitudeReason: String?
        if run.id == longestID {
            magnitudeReason = "Longest of the match"
        } else if run.id == fastestSprintID {
            magnitudeReason = "Fastest sprint of the match"
        } else if magnitude >= 0.85 {
            magnitudeReason = distancePercentile >= peakPercentile
                ? "One of your longest runs" : "One of your fastest bursts"
        }
        contributions.append((magnitudeWeight * magnitude, magnitudeReason))

        // 2. Event linkage.
        var eventComponent = 0.0
        var eventReason: String?
        for event in events {
            if let strength = positiveEventStrength(event.kind) {
                let lead = event.date.timeIntervalSince(run.interval.end)
                if lead >= 0, lead <= preEventWindow, strength > eventComponent {
                    eventComponent = strength
                    eventReason = preEventReason(event.kind)
                }
            } else if event.kind == .goalAgainstUs {
                let lag = run.interval.start.timeIntervalSince(event.date)
                if lag >= 0, lag <= responseWindow, responseEventStrength > eventComponent {
                    eventComponent = responseEventStrength
                    eventReason = "Response run after conceding"
                }
            }
        }
        contributions.append((eventLinkageWeight * eventComponent, eventReason))

        // 3. Novelty versus season baselines.
        var noveltyComponent = 0.0
        var noveltyReason: String?
        if let baselines {
            let distanceZ = baselines.stdDistance > 0
                ? (run.distanceMeters - baselines.meanDistance) / baselines.stdDistance : 0
            let peakZ = baselines.stdPeakSpeed > 0
                ? (run.peakSpeed - baselines.meanPeakSpeed) / baselines.stdPeakSpeed : 0
            let bestZ = max(distanceZ, peakZ)
            if bestZ > 0 {
                noveltyComponent = min(bestZ, noveltyZCap) / noveltyZCap
                if peakZ >= distanceZ, baselines.meanPeakSpeed > 0,
                   run.peakSpeed >= 1.3 * baselines.meanPeakSpeed {
                    noveltyReason = String(format: "%.1f× your usual sprint speed",
                                           run.peakSpeed / baselines.meanPeakSpeed)
                } else if baselines.meanDistance > 0, run.distanceMeters >= 1.3 * baselines.meanDistance {
                    noveltyReason = String(format: "%.1f× your usual run distance",
                                           run.distanceMeters / baselines.meanDistance)
                } else if noveltyComponent >= 0.3 {
                    noveltyReason = "Unusual for you"
                }
            }
        }
        contributions.append((noveltyWeight * noveltyComponent, noveltyReason))

        // 4. Directional meaning.
        var directionComponent = 0.0
        var directionReason: String?
        if let displacement = attackDisplacement[run.id],
           abs(displacement) >= minimumDirectionalDisplacementMeters {
            directionComponent = fieldLength > 0 ? min(abs(displacement) / fieldLength, 1) : 0
            directionReason = displacement > 0 ? "Deep attacking run" : "Long recovery run"
        }
        contributions.append((directionWeight * directionComponent, directionReason))

        // 5. Late-match output: the same magnitude counts for more in the closing minutes.
        var lateComponent = 0.0
        var lateReason: String?
        if totalOnPitch > 0, onPitchDuration(intervals, from: run.interval.start) <= lateWindow {
            lateComponent = magnitude
            if magnitude >= 0.5 { lateReason = "Late-match burst" }
        }
        contributions.append((lateWeight * lateComponent, lateReason))

        let total = contributions.reduce(0) { $0 + $1.added }
        // Reasons best-first; ties keep insertion order (stable via the enumerated index).
        let reasons = contributions.enumerated()
            .compactMap { index, entry in entry.reason.map { (index, entry.added, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map { $0.2 }

        return ScoredRun(segment: run, category: categoryByID[run.id],
                         score: total, reasons: reasons.isEmpty ? ["Notable run"] : reasons)
    }

    /// Fraction of values less than or equal to `value` (1.0 = the largest in the match).
    private static func percentileRank(_ value: Double, in sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let atOrBelow = sorted.reduce(0) { $0 + ($1 <= value ? 1 : 0) }
        return Double(atOrBelow) / Double(sorted.count)
    }

    /// Linkage strength for a run that *feeds* a positive event, nil for kinds that don't apply.
    private static func positiveEventStrength(_ kind: MatchEventKind) -> Double? {
        switch kind {
        case .goalMine: return 1.0
        case .assist: return 0.9
        case .goalForUs: return 0.7
        case .flag: return 0.5
        default: return nil
        }
    }

    private static func preEventReason(_ kind: MatchEventKind) -> String? {
        switch kind {
        case .goalMine: return "Just before your goal"
        case .assist: return "Set up the assist"
        case .goalForUs: return "Just before our goal"
        case .flag: return "Right before a flagged moment"
        default: return nil
        }
    }

    // MARK: Diversity selection

    private static func diversify(
        _ scored: [ScoredRun], track: [TrackPoint],
        projector: FieldProjector?, attackDisplacement: [UUID: Double],
        matchStart: Date, matchEnd: Date, limit: Int
    ) -> [ScoredRun] {
        // Precompute the similarity features once per run.
        let matchDuration = max(matchEnd.timeIntervalSince(matchStart), 1)
        let bucketSize = matchDuration / Double(diversityTimeBuckets)
        var timeBucket: [UUID: Int] = [:]
        var startCell: [UUID: (Int, Int)] = [:]
        var directionSign: [UUID: Int] = [:]
        var categoryByID: [UUID: KeyRunCategory] = [:]
        for entry in scored {
            let run = entry.segment
            let offset = run.interval.start.timeIntervalSince(matchStart)
            timeBucket[run.id] = min(diversityTimeBuckets - 1, max(0, Int(offset / bucketSize)))
            if let cell = startGridCell(run, track: track, projector: projector) {
                startCell[run.id] = cell
            }
            if let displacement = attackDisplacement[run.id], displacement != 0 {
                directionSign[run.id] = displacement > 0 ? 1 : -1
            } else {
                directionSign[run.id] = 0
            }
            categoryByID[run.id] = entry.category
        }

        func similarity(_ a: UUID, _ b: UUID) -> Double {
            var value = 0.0
            if timeBucket[a] == timeBucket[b] { value += similarityTimeWeight }
            if let categoryA = categoryByID[a], categoryA == categoryByID[b] {
                value += similarityCategoryWeight
            }
            if let cellA = startCell[a], let cellB = startCell[b] {
                let distance = hypot(Double(cellA.0 - cellB.0), Double(cellA.1 - cellB.1))
                let maxDistance = hypot(Double(diversityGridColumns - 1), Double(diversityGridRows - 1))
                if maxDistance > 0 { value += similaritySpatialWeight * (1 - min(distance / maxDistance, 1)) }
            }
            if let signA = directionSign[a], signA != 0, signA == directionSign[b] {
                value += similarityDirectionWeight
            }
            return value
        }

        var pool = scored
        var accumulatedPenalty: [UUID: Double] = [:]
        var selected: [ScoredRun] = []
        while selected.count < limit, !pool.isEmpty {
            let ranked = pool.sorted { lhs, rhs in
                let lScore = lhs.score - (accumulatedPenalty[lhs.id] ?? 0)
                let rScore = rhs.score - (accumulatedPenalty[rhs.id] ?? 0)
                if lScore != rScore { return lScore > rScore }
                if lhs.segment.interval.start != rhs.segment.interval.start {
                    return lhs.segment.interval.start < rhs.segment.interval.start
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            guard let best = ranked.first else { break }
            if best.score - (accumulatedPenalty[best.id] ?? 0) < minimumInterestingness { break }
            selected.append(best)
            pool.removeAll { $0.id == best.id }
            for candidate in pool {
                let penalty = diversityPenaltyStrength * similarity(best.id, candidate.id) * candidate.score
                accumulatedPenalty[candidate.id, default: 0] += penalty
            }
        }
        return selected
    }

    /// The (column, row) start cell of a run on the diversity grid, nil without a projector or when
    /// the start point falls outside the field.
    private static func startGridCell(_ run: RunSegment, track: [TrackPoint],
                                      projector: FieldProjector?) -> (Int, Int)? {
        guard let projector else { return nil }
        let lower = max(0, run.pointRange.lowerBound)
        guard lower < track.count,
              let normalized = projector.normalizedPoint(for: track[lower].coordinate) else { return nil }
        let column = min(diversityGridColumns - 1, max(0, Int(Double(normalized.x) * Double(diversityGridColumns))))
        let row = min(diversityGridRows - 1, max(0, Int(Double(normalized.y) * Double(diversityGridRows))))
        return (column, row)
    }

    // MARK: - Direction inference

    /// Signed long-axis displacement (meters) for each run, positive toward the attacking end of
    /// the run's period. Empty when there is no projector or the field has no length.
    private static func directionalDisplacements(
        runs: [RunSegment], track: [TrackPoint], projector: FieldProjector?,
        events: [MatchEvent], intervals: [DateInterval], matchStart: Date, matchEnd: Date
    ) -> [UUID: Double] {
        guard let projector, projector.lengthMeters > 0 else { return [:] }
        let lengthMeters = projector.lengthMeters

        // Net normalized (0...1) long-axis travel of a run, end minus start; nil if either endpoint
        // falls outside the projector's tolerance.
        func normalizedTravel(_ run: RunSegment) -> Double? {
            let lower = max(0, run.pointRange.lowerBound)
            let upper = min(track.count, run.pointRange.upperBound)
            guard lower < upper else { return nil }
            guard let startX = projector.normalizedPoint(for: track[lower].coordinate)?.x,
                  let endX = projector.normalizedPoint(for: track[upper - 1].coordinate)?.x else { return nil }
            return Double(endX - startX)
        }

        let periods = periodsForDirection(
            events: events, intervals: intervals, matchStart: matchStart, matchEnd: matchEnd
        )

        // Attacking direction (+1 / -1) for each period from its sprint bias (all-run bias fallback).
        let directions: [Double] = periods.map { period in
            let inPeriod = runs.filter { period.contains($0.interval.start) }
            let sprintBias = inPeriod
                .filter { $0.intensity == .sprint }
                .compactMap(normalizedTravel)
                .reduce(0, +)
            if sprintBias != 0 { return sprintBias > 0 ? 1 : -1 }
            let allBias = inPeriod.compactMap(normalizedTravel).reduce(0, +)
            return allBias >= 0 ? 1 : -1
        }

        var result: [UUID: Double] = [:]
        for run in runs {
            guard let travel = normalizedTravel(run) else { continue }
            let direction: Double
            if let index = periods.firstIndex(where: { $0.contains(run.interval.start) }) {
                direction = directions[index]
            } else {
                direction = directions.first ?? 1
            }
            result[run.id] = direction * travel * lengthMeters
        }
        return result
    }

    /// Periods for direction inference: explicit periodStart/periodEnd pairs, else two halves split
    /// at the midpoint of on-pitch time.
    private static func periodsForDirection(
        events: [MatchEvent], intervals: [DateInterval], matchStart: Date, matchEnd: Date
    ) -> [DateInterval] {
        let periodEvents = events
            .filter { $0.kind == .periodStart || $0.kind == .periodEnd }
            .sorted { $0.date < $1.date }

        var periods: [DateInterval] = []
        var openStart: Date?
        for event in periodEvents {
            if event.kind == .periodStart {
                openStart = event.date
            } else if let start = openStart, event.date > start {
                periods.append(DateInterval(start: start, end: event.date))
                openStart = nil
            }
        }
        if let start = openStart, matchEnd > start {
            periods.append(DateInterval(start: start, end: matchEnd))
        }
        if !periods.isEmpty { return periods }

        guard matchEnd > matchStart else {
            return [DateInterval(start: matchStart, end: max(matchEnd, matchStart.addingTimeInterval(1)))]
        }
        let midpoint = midpointOfPlayingTime(intervals: intervals, matchStart: matchStart, matchEnd: matchEnd)
        return [DateInterval(start: matchStart, end: midpoint),
                DateInterval(start: midpoint, end: matchEnd)]
    }

    /// The date at which cumulative on-pitch time reaches half of the total; the wall-clock
    /// midpoint when there are no playing intervals.
    private static func midpointOfPlayingTime(
        intervals: [DateInterval], matchStart: Date, matchEnd: Date
    ) -> Date {
        let total = intervals.reduce(0) { $0 + $1.duration }
        guard total > 0 else {
            return matchStart.addingTimeInterval(matchEnd.timeIntervalSince(matchStart) / 2)
        }
        let target = total / 2
        var accumulated = 0.0
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if accumulated + interval.duration >= target {
                return interval.start.addingTimeInterval(target - accumulated)
            }
            accumulated += interval.duration
        }
        return matchEnd
    }

    /// On-pitch time between `date` and the end of the last interval.
    private static func onPitchDuration(_ intervals: [DateInterval], from date: Date) -> TimeInterval {
        intervals.reduce(0) { sum, interval in
            guard interval.end > date else { return sum }
            return sum + interval.end.timeIntervalSince(max(interval.start, date))
        }
    }
}
