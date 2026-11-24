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
    var fieldName: String?
    /// Nil when no score was logged, which isn't nil–nil.
    var goalsUs: Int?
    var goalsThem: Int?
    /// Most interesting first; cards show at most three.
    var numbers: [ShareNumber]
    /// Nil without a route.
    var pitch: SharePitch?
    var replay: ShareReplay?

    var hasScore: Bool { goalsUs != nil && goalsThem != nil }

    /// "v Rovers", or how it went, or just what it was.
    var title: String {
        if let opponent { return "v \(opponent)" }
        guard let goalsUs, let goalsThem else { return "Match" }
        return goalsUs > goalsThem ? "Won" : goalsUs < goalsThem ? "Lost" : "Drew"
    }

    var dateText: String { date.formatted(.dateTime.month(.abbreviated).day()) }

    func subtitle(showsFieldName: Bool) -> String {
        [dateText, showsFieldName ? fieldName : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The same match with the ends swapped, for when the attacking direction was guessed wrong.
    var turnedAround: ShareMatch {
        var match = self
        match.pitch = pitch?.turnedAround
        match.replay = replay?.turnedAround
        return match
    }
}

/// What a still picture draws.
struct SharePitch: Hashable, Sendable {
    var size: PitchSize
    var heat: PitchHeat
    var marks: [PitchMark] = []
    var bestRun: PitchRun?
    var directionIsKnown = true

    var turnedAround: SharePitch {
        var pitch = self
        pitch.heat = heat.turnedAround
        pitch.marks = marks.map { PitchMark(kind: $0.kind, point: $0.point.turnedAround) }
        pitch.bestRun = bestRun.map { PitchRun(points: $0.points.map(\.turnedAround), isBest: true) }
        pitch.directionIsKnown = true
        return pitch
    }
}

/// What the replay video plays.
struct ShareReplay: Sendable {
    struct Sample: Sendable {
        var date: Date
        var point: PitchPoint
        /// Seconds until the next fix, capped; how much heat this one is worth.
        var seconds: Double
        /// Meters covered on the pitch so far.
        var distance: Double
        var topSpeed: Double
    }

    struct Moment: Sendable, Equatable {
        enum Kind: Sendable { case myGoal, goalForUs, goalAgainst, assist }
        var kind: Kind
        var date: Date
        /// Nil when there was no fix near it.
        var point: PitchPoint?
    }

    struct BestRun: Sendable {
        var run: PitchRun
        var interval: DateInterval
        var caption: String
        var detail: String
    }

    var periods: [DateInterval]
    var playing: [DateInterval]
    var samples: [Sample]
    var moments: [Moment]
    var sprintEnds: [Date]
    var bestRun: BestRun?
    var totalDistance: Double
    var topSpeed: Double?

    var turnedAround: ShareReplay {
        var replay = self
        replay.samples = samples.map { sample in
            var sample = sample
            sample.point = sample.point.turnedAround
            return sample
        }
        replay.moments = moments.map { Moment(kind: $0.kind, date: $0.date, point: $0.point?.turnedAround) }
        replay.bestRun?.run.points = bestRun?.run.points.map(\.turnedAround) ?? []
        return replay
    }
}

// MARK: - Building one

extension ShareMatch {
    /// Snapshots a loaded match and does the projecting off the main actor. Works without a route:
    /// the pitch and replay are simply absent.
    @MainActor
    static func make(detail: MatchDetailModel, summary: MatchSummary,
                     opponent: String? = nil, teamName: String? = nil) async -> ShareMatch {
        let source = Source(
            id: summary.id, start: detail.matchStart, end: detail.matchEnd, events: detail.events,
            track: detail.track, analytics: detail.analytics, summaryDistance: summary.distanceMeters,
            opponent: opponent?.nilIfBlank, teamName: teamName?.nilIfBlank, units: .current
        )
        return await Task.detached(priority: .userInitiated) { source.build() }.value
    }

    /// A value-type snapshot, so building never touches the model.
    struct Source: @unchecked Sendable {
        var id: UUID
        var start: Date
        var end: Date
        var events: [MatchEvent]
        var track: [TrackPoint]
        var analytics: MatchAnalytics?
        var summaryDistance: Double
        var opponent: String?
        var teamName: String?
        var units: UnitSystem

        private static let onFieldMarginMeters = 6.0
        private static let longestSampleSeconds = 10.0
        /// Goals are tapped in after the fact; the scorer was furthest forward just before.
        private static let tapDelay: TimeInterval = 20

        func build() -> ShareMatch {
            let us = events.filter { $0.kind == .goalForUs || $0.kind == .goalMine }.count
            let them = events.filter { $0.kind == .goalAgainstUs }.count
            var match = ShareMatch(
                id: id, date: start, teamName: teamName, opponent: opponent,
                fieldName: analytics?.fieldName?.nilIfBlank,
                goalsUs: us + them > 0 ? us : nil, goalsThem: us + them > 0 ? them : nil,
                numbers: numbers
            )
            guard let analytics, analytics.rectangle.corners.count == 4, track.count > 1 else { return match }

            let ordered = track.sorted { $0.timestamp < $1.timestamp }
            let projector = analytics.projector
            let frame = AttackFrame.infer(track: ordered, runs: analytics.runs, projector: projector,
                                          events: events, matchStart: start, matchEnd: end)
            let samples = samples(from: ordered, frame: frame, analytics: analytics)
            guard !samples.isEmpty else { return match }

            let size = PitchSize(lengthMeters: projector.lengthMeters, widthMeters: projector.widthMeters)
            let heat = PitchHeat(samples: samples.map { ($0.point, $0.seconds) })
            let moments = moments(samples: samples, directionIsKnown: frame.isKnown)
            let bestRun = bestRun(in: ordered, frame: frame, analytics: analytics)
            match.pitch = SharePitch(
                size: size, heat: heat,
                marks: moments.compactMap { moment in
                    guard let point = moment.point else { return nil }
                    switch moment.kind {
                    case .myGoal: return PitchMark(kind: .goal, point: point)
                    case .assist: return PitchMark(kind: .assist, point: point)
                    case .goalForUs, .goalAgainst: return nil
                    }
                },
                bestRun: bestRun?.run, directionIsKnown: frame.isKnown
            )
            match.replay = ShareReplay(
                periods: frame.periods.map(\.interval), playing: analytics.playingIntervals,
                samples: samples, moments: moments,
                sprintEnds: analytics.runs.filter { $0.intensity == .sprint }.map(\.interval.end).sorted(),
                bestRun: bestRun, totalDistance: analytics.workrate.totalDistanceMeters,
                topSpeed: analytics.loadMetrics?.topSpeedMetersPerSecond
            )
            return match
        }

        private var numbers: [ShareNumber] {
            var numbers: [ShareNumber] = []
            let distance = analytics.map(\.workrate.totalDistanceMeters).flatMap { $0 > 0 ? $0 : nil } ?? summaryDistance
            if distance > 0 { numbers.append(ShareNumber(units.distance(distance), label: "Distance")) }
            if let speed = analytics?.loadMetrics?.topSpeedMetersPerSecond, speed > 0 {
                numbers.append(ShareNumber(units.speed(speed), label: "Top speed"))
            }
            if !track.isEmpty, let sprints = analytics?.workrate.sprintCount, sprints > 0 {
                numbers.append(ShareNumber(value: "\(sprints)", label: sprints == 1 ? "Sprint" : "Sprints"))
            }
            let seconds = analytics?.workrate.timeOnPitch ?? end.timeIntervalSince(start)
            if seconds >= 60 { numbers.append(ShareNumber(value: "\(Int(seconds / 60))", unit: "min", label: "Played")) }
            return numbers
        }

        private func samples(from ordered: [TrackPoint], frame: AttackFrame,
                             analytics: MatchAnalytics) -> [ShareReplay.Sample] {
            let intervals = analytics.playingIntervals
            let periods = frame.periods.map(\.interval)
            var samples: [ShareReplay.Sample] = []
            var distance = 0.0, topSpeed = 0.0
            var previous: (date: Date, place: PitchPoint)?
            for (index, point) in ordered.enumerated() {
                guard periods.contains(where: { $0.contains(point.timestamp) }),
                      intervals.isEmpty || intervals.contains(where: { $0.contains(point.timestamp) }),
                      analytics.projector.isOnField(point.coordinate, marginMeters: Self.onFieldMarginMeters),
                      let place = frame.point(for: point.coordinate, at: point.timestamp) else { continue }
                if let previous, point.timestamp.timeIntervalSince(previous.date) < Self.longestSampleSeconds {
                    distance += hypot((place.across - previous.place.across) * analytics.projector.widthMeters,
                                      (place.up - previous.place.up) * analytics.projector.lengthMeters)
                }
                topSpeed = max(topSpeed, point.speedMetersPerSecond)
                previous = (point.timestamp, place)
                let gap = index + 1 < ordered.count
                    ? ordered[index + 1].timestamp.timeIntervalSince(point.timestamp) : 0
                samples.append(.init(date: point.timestamp, point: place,
                                     seconds: min(max(gap, 0), Self.longestSampleSeconds),
                                     distance: distance, topSpeed: topSpeed))
            }
            return samples
        }

        private func moments(samples: [ShareReplay.Sample], directionIsKnown: Bool) -> [ShareReplay.Moment] {
            events.compactMap { event -> ShareReplay.Moment? in
                let kind: ShareReplay.Moment.Kind
                switch event.kind {
                case .goalMine: kind = .myGoal
                case .goalForUs: kind = .goalForUs
                case .goalAgainstUs: kind = .goalAgainst
                case .assist: kind = .assist
                default: return nil
                }
                let recent = samples.filter {
                    $0.date <= event.date && event.date.timeIntervalSince($0.date) <= Self.tapDelay
                }
                let point = directionIsKnown
                    ? recent.max { $0.point.up < $1.point.up }?.point
                    : recent.last?.point
                return ShareReplay.Moment(kind: kind, date: event.date, point: point)
            }
            .sorted { $0.date < $1.date }
        }

        private func bestRun(in ordered: [TrackPoint], frame: AttackFrame,
                             analytics: MatchAnalytics) -> ShareReplay.BestRun? {
            let playing = analytics.runs.filter { run in
                frame.periods.contains { $0.interval.contains(run.interval.start) && $0.interval.contains(run.interval.end) }
            }
            // The run the top speed came from, so the film and the figures agree.
            let sprints = playing.filter { $0.intensity == .sprint }
            func quickest(_ run: RunSegment) -> Double {
                ordered.filter { run.interval.contains($0.timestamp) }.map(\.speedMetersPerSecond)
                    .filter { $0 <= SoccerLoadMetrics.outlierSpeedCapMetersPerSecond }.max() ?? run.peakSpeed
            }
            let fastest = sprints.map { (run: $0, speed: quickest($0)) }.max { $0.speed < $1.speed }
            guard let segment = fastest?.run ?? playing.max(by: { $0.distanceMeters < $1.distanceMeters }) else { return nil }
            var fixes = ordered.filter { segment.interval.contains($0.timestamp) }
            if let fastest, let peak = fixes.indices.max(by: { speed(fixes[$0]) < speed(fixes[$1]) }) {
                // Just the sprint, not the jog either side of it.
                let pace = fastest.speed * 0.5
                var first = peak, last = peak
                while first > 0, speed(fixes[first - 1]) >= pace || peak - first < 2 { first -= 1 }
                while last + 1 < fixes.count, speed(fixes[last + 1]) >= pace || last - peak < 2 { last += 1 }
                fixes = Array(fixes[first...last])
            }
            let points = fixes.compactMap { frame.point(for: $0.coordinate, at: $0.timestamp) }
            guard points.count >= 2, let start = fixes.first?.timestamp, let end = fixes.last?.timestamp, end > start else {
                return nil
            }
            let topSpeed = analytics.loadMetrics?.topSpeedMetersPerSecond
            let setTheTopSpeed = fastest.map { abs($0.speed - (topSpeed ?? -1)) < 0.05 } ?? false
            return ShareReplay.BestRun(
                run: PitchRun(points: Self.smoothed(points), isBest: true),
                interval: DateInterval(start: start, end: end),
                caption: fastest == nil ? "Longest run" : setTheTopSpeed ? "Fastest run" : "Best sprint",
                detail: setTheTopSpeed ? units.speed(topSpeed ?? 0).text : units.shortDistance(segment.distanceMeters).text
            )
        }

        private func speed(_ point: TrackPoint) -> Double {
            point.speedMetersPerSecond <= SoccerLoadMetrics.outlierSpeedCapMetersPerSecond ? point.speedMetersPerSecond : 0
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
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
