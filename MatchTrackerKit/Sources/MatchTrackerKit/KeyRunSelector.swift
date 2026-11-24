import Foundation
import CoreGraphics

// MARK: - Key runs
//
// The at most three runs worth showing one by one: the fastest, the longest, and the one just
// before your team scored.

public enum KeyRunCategory: String, Codable, CaseIterable, Sendable {
    case fastest
    case longest
    case decisive   // ended just before your team's goal
}

/// One curated run. A run that wins two categories appears once, and says so.
public struct KeyRun: Identifiable, Sendable {
    public var id: UUID { segment.id }
    public let categories: [KeyRunCategory]
    public let segment: RunSegment
    /// "Fastest run", "Longest run, just before your goal".
    public let title: String
    /// What else was true of it, if anything: "Late in the match".
    public let detail: String?
    /// The run on the portrait pitch (x 0...1 left to right, y 1 = attacking end), in order.
    public var points: [CGPoint]
    /// Seconds since the start of the match.
    public let fromT: TimeInterval
    public let toT: TimeInterval
    public var peakSpeed: Double { segment.peakSpeed }
    public var distanceMeters: Double { segment.distanceMeters }
}

public enum KeyRunSelector {
    /// 30 yards. A run this long is worth showing whatever its speed.
    static let minimumDistanceMeters = 27.4
    /// A run must end within this long before a goal to have led to it. Goals are logged late.
    static let decisiveWindow: TimeInterval = 30
    /// How near the end of the match counts as late.
    static let lateWindow: TimeInterval = 15 * 60

    /// Deterministic, best category first; empty when no run is a sprint or 30 yards.
    public static func select(runs: [RunSegment], events: [MatchEvent], interval: DateInterval) -> [KeyRun] {
        let candidates = runs
            .filter { $0.intensity == .sprint || $0.distanceMeters >= minimumDistanceMeters }
            .sorted { $0.interval.start < $1.interval.start }
        guard !candidates.isEmpty else { return [] }

        // `max` keeps the first of equals; the earlier run has the better claim.
        func best(_ runs: [RunSegment], by value: (RunSegment) -> Double) -> RunSegment? {
            runs.max { value($0) < value($1) }
        }
        let decisive = decisiveRun(among: candidates, events: events)
        var winners: [KeyRunCategory: RunSegment] = [:]
        winners[.fastest] = best(candidates, by: \.peakSpeed)
        winners[.longest] = best(candidates, by: \.distanceMeters)
        winners[.decisive] = decisive?.run

        var chosen: [RunSegment] = []
        for category in KeyRunCategory.allCases {
            if let run = winners[category], !chosen.contains(where: { $0.id == run.id }) { chosen.append(run) }
        }
        return chosen.map { run in
            let categories = KeyRunCategory.allCases.filter { winners[$0]?.id == run.id }
            return KeyRun(categories: categories, segment: run,
                          title: title(categories, goal: decisive?.goal),
                          detail: interval.end.timeIntervalSince(run.interval.start) <= lateWindow ? "Late in the match" : nil,
                          points: [],
                          fromT: run.interval.start.timeIntervalSince(interval.start),
                          toT: run.interval.end.timeIntervalSince(interval.start))
        }
    }

    /// The fastest run just before the goal the wearer had most to do with.
    private static func decisiveRun(among runs: [RunSegment],
                                    events: [MatchEvent]) -> (run: RunSegment, goal: MatchEventKind)? {
        for kind in [MatchEventKind.goalMine, .assist, .goalForUs] {
            let leadingUp = events.filter { $0.kind == kind }.flatMap { goal in
                runs.filter { (0...decisiveWindow).contains(goal.date.timeIntervalSince($0.interval.end)) }
            }
            if let run = leadingUp.max(by: { $0.peakSpeed < $1.peakSpeed }) { return (run, kind) }
        }
        return nil
    }

    private static func title(_ categories: [KeyRunCategory], goal: MatchEventKind?) -> String {
        var title: String?
        if categories.contains(.fastest) {
            title = categories.contains(.longest) ? "Fastest and longest run" : "Fastest run"
        } else if categories.contains(.longest) {
            title = "Longest run"
        }
        guard categories.contains(.decisive) else { return title ?? "" }
        let moment: String
        switch goal {
        case .goalMine: moment = "just before your goal"
        case .assist: moment = "just before your assist"
        default: moment = "just before we scored"
        }
        return title.map { "\($0), \(moment)" } ?? "Run \(moment)"
    }
}
