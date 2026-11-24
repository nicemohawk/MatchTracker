// ShareMatch.swift
// MatchTracker
//
// Everything a shared picture or replay may show about one match. Deliberately holds no
// coordinates: once a match becomes this, where it was played is at most a name.

import Foundation
import CoreGraphics
import MatchTrackerKit

/// A figure worth showing off, already in the reader's units.
struct ShareNumber: Hashable, Sendable, Identifiable {
    var value: String
    var unit: String = ""
    var label: String
    var id: String { label }

    init(value: String, unit: String = "", label: String) {
        self.value = value
        self.unit = unit
        self.label = label
    }

    init(_ measure: UnitSystem.Measure, label: String) {
        self.init(value: measure.value, unit: measure.unit, label: label)
    }
}

struct ShareMatch: Identifiable, Sendable {
    var id: UUID
    var date: Date
    var teamName: String?
    var opponent: String?
    /// "Match", "Pickup", "Indoor".
    var kind = "Match"
    var fieldName: String?
    /// Nil when no score was logged, which isn't nil–nil.
    var goalsUs: Int?
    var goalsThem: Int?
    /// Most interesting first; cards show at most three.
    var numbers: [ShareNumber]
    /// Nil without a route.
    var pitch: SharePitch?
    /// Playing and resting, for a match without a pitch to draw.
    var strip: [Float]?
    var replay: ShareReplay?

    var hasScore: Bool { goalsUs != nil && goalsThem != nil }

    /// "v Rovers", or how it went, or just what it was.
    var title: String {
        if let opponent { return "v \(opponent)" }
        guard let goalsUs, let goalsThem else { return kind }
        return goalsUs > goalsThem ? "Won" : goalsUs < goalsThem ? "Lost" : "Drew"
    }

    var dateText: String { date.formatted(.dateTime.month(.abbreviated).day()) }

    func subtitle(showsFieldName: Bool) -> String {
        [dateText, showsFieldName ? fieldName : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

/// What a still picture draws.
struct SharePitch: Hashable, Sendable {
    var size: PitchSize
    var heat: PitchHeat
    var marks: [PitchMark] = []
    var bestRun: PitchRun?
    var directionIsKnown = true
}

/// What the replay video plays.
struct ShareReplay: Sendable {
    struct Sample: Sendable {
        var date: Date
        var point: PitchPoint
        /// Seconds until the next one, capped; how much heat this one is worth.
        var seconds: Double
    }

    struct Moment: Sendable, Equatable {
        enum Kind: Sendable { case myGoal, goalForUs, goalAgainst, assist }
        var kind: Kind
        var date: Date
        /// Nil when there was no fix near it.
        var point: PitchPoint?
    }

    struct Run: Sendable {
        var end: Date
        var isSprint: Bool
        var peakSpeed: Double
    }

    struct BestRun: Sendable {
        var run: PitchRun
        var interval: DateInterval
        var caption: String
        var detail: String
    }

    var periods: [DateInterval]
    var playing: [DateInterval]
    /// On the pitch only.
    var samples: [Sample]
    var moments: [Moment]
    var runs: [Run]
    var bestRun: BestRun?
    var metersPerMinute: [Double]
    var topSpeed: Double?

    /// Meters covered by a moment in the match, finishing on the match's one distance.
    func distance(at date: Date) -> Double {
        guard let start = periods.first?.start else { return 0 }
        let minutes = max(0, date.timeIntervalSince(start) / 60)
        let whole = min(Int(minutes), metersPerMinute.count)
        let partial = metersPerMinute.indices.contains(whole) ? metersPerMinute[whole] * (minutes - Double(whole)) : 0
        return metersPerMinute.prefix(whole).reduce(0, +) + partial
    }
}

// MARK: - Building one

extension ShareMatch {
    /// Everything comes from the match's analysis, so a card says exactly what the app does. Works
    /// without a route: the pitch and replay are simply absent.
    /// - Parameter detail: Must have finished loading.
    @MainActor
    init(detail: MatchDetailModel, teamName: String? = nil) {
        let digest = detail.digest ?? MatchDigest(
            id: detail.matchIdentifier, interval: detail.playedInterval, format: detail.matchFormat,
            record: detail.record, analytics: nil)
        self.init(digest: digest, analytics: detail.analytics, events: detail.events, teamName: teamName)
    }

    init(digest: MatchDigest, analytics: MatchAnalytics?, events: [MatchEvent], teamName: String? = nil,
         units: UnitSystem = .current) {
        id = digest.id
        date = digest.startDate
        self.teamName = teamName?.nilIfBlank
        opponent = digest.opponent?.nilIfBlank
        fieldName = digest.fieldName?.nilIfBlank
        goalsUs = digest.goalsUs
        goalsThem = digest.goalsThem
        numbers = Self.numbers(digest, units: units)
        strip = digest.strip
        kind = digest.format.title
        guard let analytics, analytics.hasRoute else { return }

        let moments = Self.moments(events: events, analytics: analytics)
        let bestRun = Self.bestRun(analytics, units: units)
        pitch = SharePitch(
            size: PitchSize(analytics.rectangle), heat: PitchHeat(analytics),
            marks: moments.compactMap { moment in
                guard let point = moment.point else { return nil }
                switch moment.kind {
                case .myGoal: return PitchMark(kind: .goal, point: point)
                case .assist: return PitchMark(kind: .assist, point: point)
                case .goalForUs, .goalAgainst: return nil
                }
            },
            bestRun: bestRun?.run, directionIsKnown: analytics.isDirectionConfident
        )
        replay = ShareReplay(
            periods: Self.periods(analytics), playing: analytics.playingIntervals,
            samples: Self.samples(analytics), moments: moments,
            runs: analytics.runs.map {
                ShareReplay.Run(end: $0.interval.end, isSprint: $0.intensity == .sprint, peakSpeed: $0.peakSpeed)
            },
            bestRun: bestRun, metersPerMinute: analytics.metersPerMinute,
            topSpeed: analytics.topSpeedMetersPerSecond
        )
    }

    private static let longestSampleSeconds = 10.0
    /// Goals are tapped in after the fact; the scorer was furthest forward just before.
    private static let tapDelay: TimeInterval = 20

    private static func numbers(_ digest: MatchDigest, units: UnitSystem) -> [ShareNumber] {
        var numbers: [ShareNumber] = []
        if let distance = digest.distanceMeters { numbers.append(ShareNumber(units.distance(distance), label: "Distance")) }
        if let speed = digest.topSpeedMetersPerSecond { numbers.append(ShareNumber(units.speed(speed), label: "Top speed")) }
        if let sprints = digest.sprintCount, sprints > 0 {
            numbers.append(ShareNumber(value: "\(sprints)", label: sprints == 1 ? "Sprint" : "Sprints"))
        }
        if let stints = digest.stintCount, stints > 1 { numbers.append(ShareNumber(value: "\(stints)", label: "Stints")) }
        if digest.secondsOnPitch >= 60 {
            numbers.append(ShareNumber(value: "\(Int(digest.secondsOnPitch / 60))", unit: "min", label: "Played"))
        }
        return numbers
    }

    private static func periods(_ analytics: MatchAnalytics) -> [DateInterval] {
        let whole = analytics.interval
        guard let halftime = analytics.halftime, whole.contains(halftime.start), whole.contains(halftime.end) else {
            return [whole]
        }
        return [DateInterval(start: whole.start, end: halftime.start), DateInterval(start: halftime.end, end: whole.end)]
    }

    private static func samples(_ analytics: MatchAnalytics) -> [ShareReplay.Sample] {
        let path = analytics.pitchPath
        return path.indices.compactMap { index in
            guard path[index].onPitch else { return nil }
            let gap = index + 1 < path.count ? path[index + 1].t - path[index].t : 0
            return ShareReplay.Sample(date: analytics.interval.start.addingTimeInterval(path[index].t),
                                      point: PitchPoint(path[index]), seconds: min(gap, longestSampleSeconds))
        }
    }

    private static func moments(events: [MatchEvent], analytics: MatchAnalytics) -> [ShareReplay.Moment] {
        events.compactMap { event -> ShareReplay.Moment? in
            let kind: ShareReplay.Moment.Kind
            switch event.kind {
            case .goalMine: kind = .myGoal
            case .goalForUs: kind = .goalForUs
            case .goalAgainstUs: kind = .goalAgainst
            case .assist: kind = .assist
            default: return nil
            }
            let t = event.date.timeIntervalSince(analytics.interval.start)
            let recent = analytics.pitchPath.filter { $0.onPitch && $0.t <= t && t - $0.t <= tapDelay }
            let sample = analytics.isDirectionConfident ? recent.max { $0.y < $1.y } : recent.last
            return ShareReplay.Moment(kind: kind, date: event.date, point: sample.map { PitchPoint($0) })
        }
        .sorted { $0.date < $1.date }
    }

    private static func bestRun(_ analytics: MatchAnalytics, units: UnitSystem) -> ShareReplay.BestRun? {
        guard let run = analytics.keyRuns.first, run.points.count >= 2, run.toT > run.fromT else { return nil }
        let isFastest = run.categories.contains(.fastest)
        return ShareReplay.BestRun(
            run: PitchRun(points: smoothed(run.points.map { PitchPoint($0) }), isBest: true),
            interval: DateInterval(start: analytics.interval.start.addingTimeInterval(run.fromT), duration: run.toT - run.fromT),
            caption: run.title,
            detail: isFastest ? units.speed(run.peakSpeed).text : units.shortDistance(run.distanceMeters).text
        )
    }

    /// Takes the jitter out of a line without moving its ends.
    private static func smoothed(_ points: [PitchPoint]) -> [PitchPoint] {
        guard points.count > 3 else { return points }
        return points.indices.map { index in
            guard index > 0, index < points.count - 1 else { return points[index] }
            let around = [points[index - 1], points[index], points[index], points[index + 1]]
            return PitchPoint(across: around.map(\.across).reduce(0, +) / 4, up: around.map(\.up).reduce(0, +) / 4)
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
