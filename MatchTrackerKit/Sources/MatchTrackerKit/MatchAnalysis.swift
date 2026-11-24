import Foundation
import CoreGraphics

// MARK: - The whole-match analysis
//
// The one pipeline behind the match detail, the digest and the uploads, so they can't disagree.

/// Everything the pipeline reads. `track` and `heartRate` may run past `interval`; only what falls
/// inside it counts.
public struct MatchAnalysisInput: Sendable {
    /// When the match was played: `MatchRecord.trimmed`, or the workout's span.
    public var interval: DateInterval
    public var format: MatchFormat
    public var events: [MatchEvent]
    public var reportedPositions: [ReportedPosition]?
    public var flipsAttack: Bool?
    public var track: [TrackPoint]
    public var heartRate: [HeartRateSample]
    /// Distance HealthKit measured inside `interval`.
    public var healthDistanceMeters: Double?
    /// The saved field the match was played on, from `FieldStore.resolve`; nil infers one.
    public var savedField: FieldModel?

    public init(interval: DateInterval, format: MatchFormat, events: [MatchEvent] = [],
                reportedPositions: [ReportedPosition]? = nil, flipsAttack: Bool? = nil,
                track: [TrackPoint] = [], heartRate: [HeartRateSample] = [],
                healthDistanceMeters: Double? = nil, savedField: FieldModel? = nil) {
        self.interval = interval
        self.format = format
        self.events = events
        self.reportedPositions = reportedPositions
        self.flipsAttack = flipsAttack
        self.track = track
        self.heartRate = heartRate
        self.healthDistanceMeters = healthDistanceMeters
        self.savedField = savedField
    }

    public init(record: MatchRecord?, interval: DateInterval, format: MatchFormat, track: [TrackPoint],
                heartRate: [HeartRateSample], healthDistanceMeters: Double?, savedField: FieldModel?) {
        self.init(interval: interval, format: format, events: record?.events ?? [],
                  reportedPositions: record?.reportedPositions, flipsAttack: record?.flipsAttack,
                  track: track, heartRate: heartRate, healthDistanceMeters: healthDistanceMeters,
                  savedField: savedField)
    }
}

/// All analytics for one match.
public struct MatchAnalytics: Sendable {
    public var interval: DateInterval
    public var rectangle: OrientedRectangle
    public var projector: FieldProjector
    public var fieldID: UUID?
    public var fieldName: String?
    public var fieldSource: FieldSource?
    public var playingIntervals: [DateInterval]
    /// Landscape and not direction-normalized; prefer `heat`.
    public var heatmap: HeatmapGrid
    public var runs: [RunSegment]
    public var workrate: WorkrateReport
    public var position: PositionEstimate
    /// Nil without a route.
    public var loadMetrics: SoccerLoadMetrics?

    /// The match's one distance (see "Definitions" in Analytics.swift).
    public var distanceMeters: Double?
    /// Nil without a route, or when nothing was held for a second.
    public var topSpeedMetersPerSecond: Double?
    public var averageHeartRate: Double?
    public var maximumHeartRate: Double?
    /// Meters covered in each minute of the match, adding up to `distanceMeters`. Empty without a route.
    public var metersPerMinute: [Double]

    public var attackDirection: AttackDirection
    /// The match on the portrait pitch, about one sample every two seconds.
    public var pitchPath: [PitchSample]
    /// Portrait, row-major, row 0 the attacking end, busiest cell 1. Empty without a route.
    public var heat: [Float]
    public var thirds: PitchThirds?
    public var keyRuns: [KeyRun]

    public var heatColumns: Int { PortraitHeat.columns }
    public var heatRows: Int { PortraitHeat.rows }
    public var isDirectionConfident: Bool { attackDirection.isConfident }
    public var halftime: DateInterval? { attackDirection.halftime }
    public var hasRoute: Bool { !pitchPath.isEmpty }
}

public enum MatchAnalyzer {
    /// On/off-field slop (meters): absorbs GPS jitter and players overrunning the line without
    /// admitting warm-up laps, the bench, or the walk to the car.
    private static let onFieldMarginMeters = 6.0
    /// How far a run at full tilt goes before it stops.
    private static let overrunMarginMeters = 20.0
    /// Standing in goal for this much of a match is keeping goal.
    private static let goalkeepingShare = 0.25
    private static let minimumRoutePoints = 30
    private static let maximumSampleSeconds = 10.0
    private static let pathSampleSeconds = 1.9   // fixes jitter around the second

    /// Nil only when there is neither a route nor heart rate nor distance to say anything with.
    /// Sweeps tens of thousands of points: never call it on the main actor.
    public static func analyze(_ input: MatchAnalysisInput) -> MatchAnalytics? {
        let interval = input.interval
        var track = input.track.filter { interval.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
        // A fix or two is not a route.
        if track.count < minimumRoutePoints { track = [] }
        let heartRate = input.heartRate.filter { interval.contains($0.date) }
        let averageHeartRate = heartRate.isEmpty ? nil : mean(heartRate.map(\.bpm))
        let maximumHeartRate = heartRate.map(\.bpm).max()
        let healthDistance = input.healthDistanceMeters.flatMap { $0 > 0 ? $0 : nil }
        let recordedIntervals = SubstitutionTracker.playingIntervals(
            events: input.events, matchStart: interval.start, matchEnd: interval.end)

        guard let field = resolveField(track: track, saved: input.savedField) else {
            guard input.format == .indoor || !heartRate.isEmpty || healthDistance != nil else { return nil }
            // No route: effort comes from heart rate alone, and nothing is placed on a pitch.
            var workrate = WorkrateAnalyzer.analyze(
                track: [], runs: [], playingIntervals: recordedIntervals,
                heartRate: heartRate, context: MatchContext(format: .indoor))
            workrate.averageHeartRate = averageHeartRate
            workrate.totalDistanceMeters = healthDistance ?? 0
            return MatchAnalytics(
                interval: interval, rectangle: placeholderRectangle,
                projector: FieldProjector(rectangle: placeholderRectangle),
                playingIntervals: recordedIntervals,
                heatmap: HeatmapGrid(columns: 30, rows: 20, cells: []), runs: [], workrate: workrate,
                position: PositionEstimate(role: .midfielder, side: .center, confidence: 0,
                                           meanPoint: CGPoint(x: 0.5, y: 0.5), periodMeanPoints: []),
                distanceMeters: healthDistance, averageHeartRate: averageHeartRate,
                maximumHeartRate: maximumHeartRate, metersPerMinute: [],
                attackDirection: AttackDirection(flipsAttack: false, halftime: nil, isConfident: false),
                pitchPath: [], heat: [], keyRuns: [])
        }

        let projector = FieldProjector(rectangle: field.rectangle)
        let halftime = input.format == .match
            ? PeriodDetector.halftime(track: track, events: input.events, interval: interval) : nil
        let derivedIntervals = PlayIntervalDeriver.playingIntervals(
            track: track, field: field.rectangle, events: input.events,
            matchStart: interval.start, matchEnd: interval.end, marginMeters: onFieldMarginMeters)
        // Nobody was playing after the last movement, however long the recording ran on.
        let forgotten = TrimAdvisor.suggestedEnd(recorded: interval, track: track, heartRate: heartRate,
                                                 field: field.rectangle).map { DateInterval(start: $0, end: interval.end) }
        let playingIntervals = [halftime, forgotten].reduce(
            derivedIntervals.isEmpty ? recordedIntervals : derivedIntervals) { subtract($1, from: $0) }

        // Places are drawn and speeds taken only from on-field play, so warm-up laps and the bench
        // never smear onto the pitch. Standing about waiting is on the pitch but isn't play.
        let isOnField = track.map { projector.isOnField($0.coordinate, marginMeters: onFieldMarginMeters) }
        let isPlaying = track.indices.map { isOnField[$0] && isWithin(track[$0].timestamp, intervals: playingIntervals) }
        let normalized = track.map { projector.normalizedPoint(for: $0.coordinate) }
        let isWaiting = WaitingDetector.isWaiting(track)
        let isInGoal = track.indices.map { isPlaying[$0] && isWaiting[$0] && isInGoalmouth(normalized[$0]) }
        // A goalkeeper's standing is the job: said so, or spent a good part of the match at it.
        let isGoalkeeper = input.reportedPositions?.contains { $0.role == .goalkeeper } == true
            || Double(isInGoal.filter { $0 }.count) >= goalkeepingShare * Double(max(isPlaying.filter { $0 }.count, 1))
        let isInPlay = track.indices.map { isPlaying[$0] && (!isWaiting[$0] || (isGoalkeeper && isInGoal[$0])) }
        let onFieldTrack = track.indices.filter { isOnField[$0] }.map { track[$0] }
        // A run may carry over the line chasing a ball. One that never set foot on the pitch is
        // somebody warming up beside it.
        let isRunning = track.indices.map {
            isPlaying[$0] || (projector.isOnField(track[$0].coordinate, marginMeters: overrunMarginMeters)
                && isWithin(track[$0].timestamp, intervals: playingIntervals))
        }
        let runs = RunDetector.detectRuns(in: track, isOnPitch: isRunning)
            .filter { isPlaying[$0.pointRange].contains(true) }

        var workrate = WorkrateAnalyzer.analyze(
            track: track, runs: runs, playingIntervals: playingIntervals, heartRate: heartRate,
            context: MatchContext(format: input.format, fieldLengthMeters: field.rectangle.lengthMeters))
        workrate.averageHeartRate = averageHeartRate
        let steps = trackStepDistances(track)
        let distance = healthDistance ?? steps.reduce(0, +)
        workrate.totalDistanceMeters = distance

        // The one direction every place below is drawn in.
        let placed = track.indices.compactMap { index in
            isInPlay[index] ? normalized[index].map { (date: track[index].timestamp, point: $0) } : nil
        }
        let direction = AttackDirection.resolve(
            points: placed, format: input.format, halftime: halftime, interval: interval,
            events: input.events, reportedPositions: input.reportedPositions, chosen: input.flipsAttack)
        let portrait = track.indices.map { index in
            normalized[index].map { clamped(direction.portrait($0, at: track[index].timestamp)) }
        }

        let weighted = track.indices.dropLast().compactMap { index -> (point: CGPoint, seconds: Double)? in
            guard isInPlay[index], let point = portrait[index] else { return nil }
            let gap = track[index + 1].timestamp.timeIntervalSince(track[index].timestamp)
            return (point, min(max(0, gap), maximumSampleSeconds))
        }
        let isInside = normalized.map { $0.map { (0...1).contains($0.x) && (0...1).contains($0.y) } ?? false }
        let keyRuns = KeyRunSelector.select(runs: runs, events: input.events, interval: interval,
                                            isInside: isInside).map { run in
            var run = run
            // An end past the lines would be drawn held at them, pointing at nothing.
            let inside = run.segment.pointRange.filter { isInside[$0] }
            if let first = inside.first, let last = inside.last {
                run.points = portrait[first...last].compactMap { $0 }
            }
            return run
        }

        return MatchAnalytics(
            interval: interval,
            rectangle: field.rectangle, projector: projector,
            fieldID: field.id, fieldName: field.name, fieldSource: field.source,
            playingIntervals: playingIntervals,
            heatmap: HeatmapGrid.compute(points: onFieldTrack, projector: projector, columns: 30, rows: 20,
                                         playingIntervals: playingIntervals),
            runs: runs, workrate: workrate,
            position: PositionAnalyzer.estimate(
                points: onFieldTrack, projector: projector,
                events: halves(of: interval, around: halftime), playingIntervals: playingIntervals),
            loadMetrics: SoccerLoadMetrics.compute(track: track, playingIntervals: playingIntervals, counted: (runs, isRunning)),
            distanceMeters: distance > 0 ? distance : nil,
            topSpeedMetersPerSecond: topSpeed(of: track, runs: runs, where: { isPlaying[$0] }),
            averageHeartRate: averageHeartRate, maximumHeartRate: maximumHeartRate,
            metersPerMinute: metersPerMinute(track: track, steps: steps, interval: interval, total: distance),
            attackDirection: direction,
            pitchPath: pitchPath(track: track, portrait: portrait, isInPlay: isInPlay, start: interval.start),
            heat: PortraitHeat.compute(points: weighted),
            thirds: thirds(weighted),
            keyRuns: keyRuns)
    }

    // MARK: Field

    /// Stands in for the projector-dependent fields of a match without a route, which nothing draws.
    private static let placeholderRectangle = OrientedRectangle(
        center: Coordinate2D(latitude: 0, longitude: 0),
        lengthMeters: 40, widthMeters: 20, headingDegrees: 0, corners: [])

    /// The box, near enough: the last sixth of the pitch, in front of goal.
    private static func isInGoalmouth(_ point: CGPoint?) -> Bool {
        guard let point else { return false }
        return abs(point.x - 0.5) > 0.33 && abs(point.y - 0.5) < 0.25
    }

    private static func resolveField(
        track: [TrackPoint], saved: FieldModel?
    ) -> (rectangle: OrientedRectangle, id: UUID?, name: String?, source: FieldSource?)? {
        guard !track.isEmpty else { return nil }
        if let saved { return (saved.rectangle, saved.id, saved.name, saved.source) }
        let core = coreOfPlay(track)
        // The dense core of play, not a bounding box, so an inferred field lands on the pitch —
        // unless it left a good part of the play outside.
        if let fitted = FieldFitter.fitFieldRectangle(track: track) {
            let projector = FieldProjector(rectangle: fitted)
            let inside = core.filter { projector.isOnField($0, marginMeters: onFieldMarginMeters) }.count
            if Double(inside) >= 0.8 * Double(core.count) { return (fitted, nil, nil, .inferred) }
        }
        return FieldGeometry.fitOrientedRectangle(to: core).map { ($0, nil, nil, nil) }
    }

    /// Where the wearer was while moving at a player's speeds, short of the walk from the car and
    /// the drive home: within a pitch's reach of the middle, less the furthest few.
    private static func coreOfPlay(_ track: [TrackPoint]) -> [Coordinate2D] {
        let moving = zip(track, rawPointSpeeds(track))
            .filter { $1 >= 1 && $1 <= SpeedThresholds.plausibleMaximum
                && $0.horizontalAccuracy <= TrackPoint.fieldTrainingHorizontalAccuracy }
            .map(\.0.coordinate)
        let coordinates = moving.count >= 60 ? moving : track.map(\.coordinate)
        let middle = Coordinate2D(latitude: median(coordinates.map(\.latitude)),
                                  longitude: median(coordinates.map(\.longitude)))
        let distances = coordinates.map { haversineMeters($0, middle) }
        let reach = min(percentile(distances, 0.98), 80)
        return zip(coordinates, distances).filter { $1 <= reach }.map(\.0)
    }

    // MARK: Pieces

    private static func subtract(_ gap: DateInterval?, from intervals: [DateInterval]) -> [DateInterval] {
        guard let gap else { return intervals }
        return intervals.flatMap { interval -> [DateInterval] in
            guard let overlap = interval.intersection(with: gap), overlap.duration > 0 else { return [interval] }
            return [(interval.start, overlap.start), (overlap.end, interval.end)]
                .filter { $0.0 < $0.1 }
                .map { DateInterval(start: $0.0, end: $0.1) }
        }
    }

    /// Period events for the analyzers that read them, free of any automatic ones on the record.
    private static func halves(of interval: DateInterval, around halftime: DateInterval?) -> [MatchEvent] {
        guard let halftime, interval.contains(halftime.start), interval.contains(halftime.end) else { return [] }
        return [MatchEvent(kind: .periodStart, date: interval.start),
                MatchEvent(kind: .periodEnd, date: halftime.start),
                MatchEvent(kind: .periodStart, date: halftime.end),
                MatchEvent(kind: .periodEnd, date: interval.end)]
    }

    private static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    private static func pitchPath(track: [TrackPoint], portrait: [CGPoint?], isInPlay: [Bool],
                                  start: Date) -> [PitchSample] {
        let speeds = rawPointSpeeds(track)
        var path: [PitchSample] = []
        var last: Date?
        for index in track.indices {
            let date = track[index].timestamp
            guard let point = portrait[index],
                  last.map({ date.timeIntervalSince($0) >= pathSampleSeconds }) ?? true else { continue }
            path.append(PitchSample(t: date.timeIntervalSince(start), x: Double(point.x), y: Double(point.y),
                                    speed: min(speeds[index], SpeedThresholds.plausibleMaximum),
                                    onPitch: isInPlay[index]))
            last = date
        }
        return path
    }

    private static func thirds(_ weighted: [(point: CGPoint, seconds: Double)]) -> PitchThirds? {
        let total = weighted.reduce(0) { $0 + $1.seconds }
        guard total > 0 else { return nil }
        let defensive = weighted.filter { $0.point.y < 1.0 / 3 }.reduce(0) { $0 + $1.seconds } / total
        let attacking = weighted.filter { $0.point.y >= 2.0 / 3 }.reduce(0) { $0 + $1.seconds } / total
        return PitchThirds(defensive: defensive, middle: 1 - defensive - attacking, attacking: attacking)
    }

    private static func metersPerMinute(track: [TrackPoint], steps: [Double], interval: DateInterval,
                                        total: Double) -> [Double] {
        var minutes = [Double](repeating: 0, count: max(1, Int((interval.duration / 60).rounded(.up))))
        for (point, step) in zip(track, steps) {
            minutes[min(Int(point.timestamp.timeIntervalSince(interval.start) / 60), minutes.count - 1)] += step
        }
        let measured = minutes.reduce(0, +)
        return measured > 0 ? minutes.map { $0 * total / measured } : []
    }
}

// MARK: - Digest

public extension MatchDigest {
    /// `analytics` is nil when there was nothing to analyze.
    init(id: UUID, interval: DateInterval, format: MatchFormat, record: MatchRecord?, analytics: MatchAnalytics?) {
        self.init(id: id, startDate: interval.start, endDate: interval.end, format: format)
        opponent = record?.opponent
        let events = record?.events ?? []
        if let score = record?.score { (goalsUs, goalsThem) = (score.us, score.them) }
        myGoals = record?.score?.mine ?? 0
        myAssists = events.filter { $0.kind == .assist }.count
        guard let analytics else {
            fieldID = record?.fieldID
            return
        }

        fieldID = analytics.fieldID ?? (analytics.hasRoute ? nil : record?.fieldID)
        fieldName = analytics.fieldName
        distanceMeters = analytics.distanceMeters
        secondsOnPitch = analytics.workrate.timeOnPitch
        averageHeartRate = analytics.averageHeartRate
        hasRoute = analytics.hasRoute
        if hasRoute || averageHeartRate != nil { effort = analytics.workrate.workrateScore }
        if hasRoute {
            topSpeedMetersPerSecond = analytics.topSpeedMetersPerSecond
            sprintCount = analytics.runs.sprintCount
            heat = PortraitHeat.thumbnail(analytics.heat)
            heatIsDirected = analytics.isDirectionConfident
        }
    }
}
