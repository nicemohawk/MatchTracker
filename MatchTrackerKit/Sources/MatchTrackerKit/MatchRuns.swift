import CoreGraphics
import Foundation

// MARK: - One run

/// A run, and what it was: where it went, how long after the last one, and what came of it.
public struct MatchRun: Identifiable, Sendable {
    public enum Heading: CaseIterable, Sendable { case forward, back, across }
    public enum Side: CaseIterable, Sendable { case left, middle, right }

    public var id: UUID { segment.id }
    public let segment: RunSegment
    /// On the portrait pitch (x 0...1 left to right, y 1 = attacking end), in order.
    public let points: [CGPoint]
    /// Seconds since the start of the match.
    public let fromT: TimeInterval
    public let toT: TimeInterval
    /// Nil when nobody knows which end is which.
    public let heading: Heading?
    /// Nil when nobody knows which end is which, so left and right could be either.
    public let side: Side?
    /// "Into the box", "from the final third". Nil when there's nothing to say.
    public let place: String?
    /// Playing time since the run before ended. Nil for the first of a half or a spell.
    public let gapBefore: TimeInterval?
    /// "Fastest run", "Run just before your goal".
    public let title: String?

    public var isSprint: Bool { segment.intensity == .sprint }
    public var peakSpeed: Double { segment.peakSpeed }
    public var distanceMeters: Double { segment.distanceMeters }
    public var duration: TimeInterval { segment.interval.duration }

    /// "Forward down the right, into the box".
    public var story: String? {
        guard let heading else { return nil }
        let way: String
        switch (heading, side) {
        case (.forward, .left?): way = "Forward down the left"
        case (.forward, .right?): way = "Forward down the right"
        case (.forward, _): way = "Forward through the middle"
        case (.back, .left?): way = "Back down the left"
        case (.back, .right?): way = "Back down the right"
        case (.back, _): way = "Back through the middle"
        case (.across, _):
            let rightward = (points.last?.x ?? 0) >= (points.first?.x ?? 0)
            way = rightward ? "Across to the right" : "Across to the left"
        }
        return place.map { "\(way), \($0)" } ?? way
    }

    /// The shortest net movement that has a direction at all. Less is a turn or a loop.
    static let minimumTravelMeters = 6.0

    static func heading(of points: [CGPoint], in field: OrientedRectangle) -> Heading? {
        guard let first = points.first, let last = points.last else { return nil }
        let across = Double(last.x - first.x) * field.widthMeters, up = Double(last.y - first.y) * field.lengthMeters
        guard hypot(across, up) >= minimumTravelMeters, abs(up) >= abs(across) * 0.6 else { return .across }
        return up > 0 ? .forward : .back
    }

    static func side(of points: [CGPoint]) -> Side? {
        guard !points.isEmpty else { return nil }
        let x = points.reduce(0) { $0 + $1.x } / CGFloat(points.count)
        return x < 0.34 ? .left : x > 0.66 ? .right : .middle
    }

    static func place(of points: [CGPoint], heading: Heading?) -> String? {
        guard let first = points.first, let last = points.last, let heading else { return nil }
        func isInBox(_ point: CGPoint) -> Bool { point.y > 0.84 && abs(point.x - 0.5) < 0.31 }
        func isInOwnBox(_ point: CGPoint) -> Bool { point.y < 0.16 && abs(point.x - 0.5) < 0.31 }
        switch heading {
        case .forward:
            if isInBox(last) { return "into the box" }
            if last.y > 2.0 / 3, first.y < 2.0 / 3 { return "into the final third" }
            if first.y < 1.0 / 3, last.y > 1.0 / 3 { return "out of defense" }
        case .back:
            if isInOwnBox(last) { return "into your own box" }
            if first.y > 2.0 / 3 { return "from the final third" }
            if first.y > 1.0 / 2, last.y < 1.0 / 2 { return "into your own half" }
        case .across:
            return nil
        }
        return nil
    }
}

// MARK: - All of them

/// What a match's runs add up to.
public struct RunReport: Sendable {
    public struct Spell: Equatable, Sendable {
        public let start: Date
        public let end: Date
        public let count: Int
    }

    public let runs: [MatchRun]
    public let sprints: Int
    /// Covered at running speed or faster.
    public let meters: Double
    /// The usual wait from one run to the next, while playing. Nil with fewer than five to go by.
    public let typicalGap: TimeInterval?
    /// Where they came thickest. Nil when no ten minutes stood out.
    public let busiest: Spell?
    /// Runs an hour of play in each half. Nil without both.
    public let halves: (first: Double, second: Double)?

    public func count(_ heading: MatchRun.Heading) -> Int { runs.filter { $0.heading == heading }.count }
    public var knowsHeadings: Bool { runs.contains { $0.heading != nil } }

    static let spellLength: TimeInterval = 10 * 60

    public init(runs: [MatchRun], playing: [DateInterval], halftime: DateInterval?) {
        self.runs = runs
        sprints = runs.filter(\.isSprint).count
        meters = runs.reduce(0) { $0 + $1.distanceMeters }

        let gaps = runs.compactMap(\.gapBefore).sorted()
        typicalGap = gaps.count >= 5 ? gaps[gaps.count / 2] : nil

        // Standing out means half as many again as ten minutes usually held.
        var best: Spell?
        for run in runs {
            let start = run.segment.interval.start, end = start.addingTimeInterval(Self.spellLength)
            let inside = runs.filter { $0.segment.interval.start >= start && $0.segment.interval.start < end }
            if inside.count > best?.count ?? 0 {
                best = Spell(start: start, end: inside.last?.segment.interval.end ?? end, count: inside.count)
            }
        }
        let played = playing.reduce(0) { $0 + $1.duration }
        let expected = played > 0 ? Double(runs.count) * Self.spellLength / played : 0
        busiest = best.flatMap { $0.count >= 4 && Double($0.count) >= expected * 1.5 ? $0 : nil }

        if let halftime {
            func rate(_ isIn: (Date) -> Bool, _ limit: DateInterval?) -> Double? {
                guard let limit else { return nil }
                let seconds = playing.reduce(0) { $0 + ($1.intersection(with: limit)?.duration ?? 0) }
                guard seconds >= 10 * 60 else { return nil }
                return Double(runs.filter { isIn($0.segment.interval.start) }.count) / seconds * 3600
            }
            let before = playing.first.map { DateInterval(start: min($0.start, halftime.start), end: halftime.start) }
            let after = playing.last.map { DateInterval(start: halftime.end, end: max($0.end, halftime.end)) }
            if let first = rate({ $0 < halftime.start }, before), let second = rate({ $0 >= halftime.start }, after) {
                halves = (first, second)
            } else {
                halves = nil
            }
        } else {
            halves = nil
        }
    }

    /// The one thing most worth saying.
    public var headline: String? {
        guard runs.count >= 5 else { return nil }
        if let halves, runs.count >= 8, max(halves.first, halves.second) > 0 {
            let change = halves.second / max(halves.first, 0.01)
            if change <= 0.65 { return "You ran less after half-time: \(percent(1 - change)) fewer runs for the time you played." }
            if change >= 1.5 { return "You got stronger: \(percent(change - 1)) more runs after half-time for the time you played." }
        }
        if knowsHeadings {
            let forward = count(.forward), back = count(.back)
            if Double(forward) >= Double(runs.count) * 0.6 { return "\(forward) of your \(runs.count) runs went forward." }
            if Double(back) >= Double(runs.count) * 0.45, back > forward { return "You did the running back: \(back) of \(runs.count) runs toward your own goal." }
            let sides = MatchRun.Side.allCases.map { side in (side, runs.filter { $0.side == side }.count) }
            if let most = sides.max(by: { $0.1 < $1.1 }), Double(most.1) >= Double(runs.count) * 0.6 {
                switch most.0 {
                case .left: return "Most of your running was down the left."
                case .right: return "Most of your running was down the right."
                case .middle: return "Most of your running was through the middle."
                }
            }
        }
        return typicalGap.map { "You ran again about every \(Self.spoken($0))." }
    }

    private func percent(_ share: Double) -> String { share.formatted(.percent.precision(.fractionLength(0))) }

    /// "3 min", "40 sec".
    public static func spoken(_ seconds: TimeInterval) -> String {
        seconds >= 90 ? "\(Int((seconds / 60).rounded())) min" : "\(Int(seconds.rounded())) sec"
    }
}

// MARK: - Making them

extension MatchRun {
    /// - Parameters:
    ///   - points: The run's portrait points.
    ///   - knowsDirection: Whether up is really the way they were attacking.
    static func all(from runs: [RunSegment], points: (RunSegment) -> [CGPoint], keyRuns: [KeyRun], field: OrientedRectangle,
                    knowsDirection: Bool, playing: [DateInterval], start: Date) -> [MatchRun] {
        let ordered = runs.sorted { $0.interval.start < $1.interval.start }
        return ordered.enumerated().map { index, segment in
            let points = points(segment)
            let heading = knowsDirection ? heading(of: points, in: field) : nil
            let before = index > 0 ? ordered[index - 1].interval.end : nil
            // A rest on the bench or at half-time isn't a rest between runs.
            let gap = before.flatMap { before in
                playing.contains { $0.contains(before) && $0.contains(segment.interval.start) }
                    ? max(0, segment.interval.start.timeIntervalSince(before)) : nil
            }
            return MatchRun(segment: segment, points: points, fromT: segment.interval.start.timeIntervalSince(start),
                            toT: segment.interval.end.timeIntervalSince(start), heading: heading,
                            side: knowsDirection ? side(of: points) : nil, place: place(of: points, heading: heading),
                            gapBefore: gap, title: keyRuns.first { $0.id == segment.id }.map(\.title))
        }
    }
}
