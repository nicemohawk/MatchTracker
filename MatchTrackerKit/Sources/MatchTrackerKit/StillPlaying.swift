import Foundation

// MARK: - Is the match over?
//
// A match left recording is the commonest way to spoil one: the drive home counts as play, or the
// night goes into Health as a nine-hour workout. Nothing here ends a match that could still be going
// on. It asks, says why, proposes when play ended, and only where playing is impossible does it stop
// waiting for an answer.
//
// No one signal says "over". Goalkeepers stand for a half, some football is walked, tournaments have
// long sit-outs and a substitute may not run all day. So not running counts only along with a heart
// that has settled below anything the session held before it, or, with no heart rate to go by, with
// not moving at all.

public struct StillPlaying: Sendable {
    public enum Reason: String, Hashable, Sendable {
        case left           // driven off, or far from the pitch
        case noPlay         // no running, and a heart at rest, for longer than any break
        case longSession    // longer than most bookings
    }

    public struct Question: Equatable, Sendable {
        public var reason: Reason
        /// When play ended, as far as anything can tell.
        public var end: Date
        /// When it was first asked.
        public let asked: Date
        fileprivate var lastBuzz: Date
        fileprivate var buzzes = 1
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Also asked again while it goes unanswered.
        case ask(Question)
        /// They're playing after all.
        case withdraw
        case end(Question, why: String)
    }

    /// Everything known at one moment of a match.
    public struct Evidence: Sendable {
        public var now: Date
        public var start: Date
        public var format: MatchFormat
        public var isBenched: Bool
        public var track: [TrackPoint]
        /// A saved field that holds the play.
        public var field: OrientedRectangle?
        public var heartRate: [HeartRateSample]
        /// The last running seen by GPS or the wrist.
        public var lastRun: Date?
        /// Whether running would be seen if there were any.
        public var canSeeRuns: Bool

        public init(now: Date, start: Date, format: MatchFormat, isBenched: Bool = false, track: [TrackPoint] = [],
                    field: OrientedRectangle? = nil, heartRate: [HeartRateSample] = [], lastRun: Date? = nil,
                    canSeeRuns: Bool) {
            self.now = now
            self.start = start
            self.format = format
            self.isBenched = isBenched
            self.track = track
            self.field = field
            self.heartRate = heartRate
            self.lastRun = lastRun
            self.canSeeRuns = canSeeRuns
        }

        var isIndoor: Bool { format == .indoor }

        /// Longer than any break there is in this kind of match.
        var longestBreak: TimeInterval {
            if isBenched { return 50 * 60 }
            return format == .match ? 20 * 60 : 35 * 60
        }
    }

    public private(set) var question: Question?

    /// Kickoff, or when a relaunch began watching again.
    private let watchingSince: Date
    private var silencedUntil: [Reason: Date] = [:]
    private var lastAnswer: Date?
    private var lastDeniedLeaving: Date?
    private var impossibleSince: Date?
    private var noPlaySince: Date?
    /// Heart rates below this are the wearer at rest, once they've been seen to be.
    private var restingBelow: Double?

    private static let restingWindow: TimeInterval = 30 * 60
    private static let longest: TimeInterval = 150 * 60
    private static let silence: [Reason: TimeInterval] = [.left: 60 * 60, .noPlay: 20 * 60, .longSession: 60 * 60]
    private static let shortestSilence: TimeInterval = 20 * 60
    private static let afterWithdrawing: TimeInterval = 10 * 60
    private static let betweenBuzzes: TimeInterval = 5 * 60
    private static let mostBuzzes = 4
    /// Asked this long, and somewhere or somehow that can't be playing for as long.
    private static let impossiblePatience: TimeInterval = 10 * 60
    private static let impossibleMeters = 1000.0
    private static let noPlayPatience: TimeInterval = 90 * 60

    public init(watchingSince: Date) {
        self.watchingSince = watchingSince
    }

    // MARK: Asking

    /// Sweeps the whole match: every half minute is often enough.
    public mutating func consider(_ evidence: Evidence) -> Action {
        let now = evidence.now
        impossibleSince = Self.isImpossible(evidence) ? impossibleSince ?? now : nil
        let isOver = isOver(evidence)
        noPlaySince = isOver ? noPlaySince ?? lastSign(evidence) : nil
        var reasons: [Reason] = []
        if !evidence.isIndoor, Self.hasLeft(evidence.track, evidence.field) { reasons.append(.left) }
        if isOver { reasons.append(.noPlay) }
        if now.timeIntervalSince(evidence.start) > Self.longest { reasons.append(.longSession) }

        guard var question else {
            guard let reason = reasons.first(where: { !isSilenced($0, at: now) }) else { return .none }
            let asked = Question(reason: reason, end: proposedEnd(evidence, reason), asked: now, lastBuzz: now)
            question = asked
            return .ask(asked)
        }
        guard let reason = reasons.first(where: { $0 == question.reason || !isSilenced($0, at: now) }) else {
            self.question = nil
            silencedUntil[question.reason] = now.addingTimeInterval(Self.afterWithdrawing)
            return .withdraw
        }
        question.reason = reason
        question.end = proposedEnd(evidence, reason)
        if let why = reasonToStopWaiting(question, evidence) {
            self.question = nil
            return .end(question, why: why)
        }
        let isDue = question.buzzes < Self.mostBuzzes && now.timeIntervalSince(question.lastBuzz) >= Self.betweenBuzzes
        if isDue {
            question.buzzes += 1
            question.lastBuzz = now
        }
        self.question = question
        return isDue ? .ask(question) : .none
    }

    /// "Still playing": believed, for a while.
    public mutating func answerStillPlaying(at now: Date) {
        guard let question else { return }
        for reason in [Reason.left, .noPlay, .longSession] {
            let silence = reason == question.reason ? Self.silence[reason] ?? Self.shortestSilence : Self.shortestSilence
            silencedUntil[reason] = max(now.addingTimeInterval(silence), silencedUntil[reason] ?? now)
        }
        lastAnswer = now
        if question.reason == .left { lastDeniedLeaving = now }
        self.question = nil
    }

    private func isSilenced(_ reason: Reason, at now: Date) -> Bool {
        silencedUntil[reason].map { now < $0 } ?? false
    }

    // MARK: Ending

    /// When a match ended by hand really ended: before the journey home, if it was still recording
    /// through that. Nil when there's nothing to leave out, or the wearer has said they hadn't left.
    public func endBeforeLeaving(recorded: DateInterval, track: [TrackPoint], field: OrientedRectangle?) -> Date? {
        guard let end = Self.endBeforeLeaving(recorded: recorded, track: track, field: field) else { return nil }
        if let lastDeniedLeaving, lastDeniedLeaving > end { return nil }
        return min(max(end, lastAnswer ?? end), recorded.end)
    }

    private static func endBeforeLeaving(recorded: DateInterval, track: [TrackPoint], field: OrientedRectangle?) -> Date? {
        guard hasLeft(track, field),
              let end = TrimAdvisor.atThePitch(recorded: recorded, track: track, field: field)?.end,
              end < recorded.end else { return nil }
        return end
    }

    private static func hasLeft(_ track: [TrackPoint], _ field: OrientedRectangle?) -> Bool {
        let usable = track.filter { $0.horizontalAccuracy <= TrackPoint.maximumUsableHorizontalAccuracy }
        return TrimAdvisor.hasLeft(track: usable, field: field) && !TrimAdvisor.playsElsewhere(track: usable, field: field)
    }

    private func proposedEnd(_ evidence: Evidence, _ reason: Reason) -> Date {
        let soFar = DateInterval(start: evidence.start, end: max(evidence.now, evidence.start))
        var end = noPlaySince ?? evidence.now
        if !evidence.isIndoor, let left = Self.endBeforeLeaving(recorded: soFar, track: evidence.track, field: evidence.field) {
            end = min(end, left)
        } else if reason == .left {
            end = min(end, evidence.lastRun ?? evidence.now)
        }
        // Never so early that ending it would look like an accidental start.
        return min(max(end, evidence.start.addingTimeInterval(60)), evidence.now)
    }

    private func reasonToStopWaiting(_ question: Question, _ evidence: Evidence) -> String? {
        let now = evidence.now
        guard now.timeIntervalSince(question.asked) >= Self.impossiblePatience else { return nil }
        if question.reason == .left, let impossibleSince, now.timeIntervalSince(impossibleSince) >= Self.impossiblePatience {
            return "far from the pitch, or driving, for \(Int(now.timeIntervalSince(impossibleSince) / 60)) min"
        }
        if let noPlaySince {
            let quiet = now.timeIntervalSince(max(noPlaySince, lastAnswer ?? noPlaySince))
            if quiet >= Self.noPlayPatience { return "no sign of play for \(Int(quiet / 60)) min" }
        }
        return nil
    }

    private static func isImpossible(_ evidence: Evidence) -> Bool {
        guard !evidence.isIndoor, let last = evidence.track.last else { return false }
        if last.speedMetersPerSecond >= TrimAdvisor.vehicleSpeed { return true }
        return TrimAdvisor.metersFromPlay(track: evidence.track, field: evidence.field).map { $0 > impossibleMeters } ?? false
    }

    // MARK: Signs of play

    /// No running for longer than any break, and either a heart at rest or no moving at all.
    private mutating func isOver(_ evidence: Evidence) -> Bool {
        let now = evidence.now
        let lastRun = [evidence.lastRun, lastAnswer, watchingSince].compactMap { $0 }.max() ?? watchingSince
        let hasStopped = now.timeIntervalSince(lastRun) >= (evidence.canSeeRuns ? evidence.longestBreak : Self.restingWindow)
        let isResting = isResting(evidence)   // always asked: it remembers
        guard hasStopped, !isOnField(evidence) else { return false }
        if let isResting { return isResting }
        return !evidence.isIndoor && evidence.canSeeRuns && isStill(evidence)
    }

    /// The last moment that could have been play.
    private func lastSign(_ evidence: Evidence) -> Date {
        let warm = restingBelow.flatMap { resting in evidence.heartRate.last { $0.bpm >= resting }?.date }
        let moving = warm == nil ? evidence.track.last { (1..<TrimAdvisor.vehicleSpeed).contains($0.speedMetersPerSecond) }?.timestamp : nil
        return [evidence.lastRun, warm, moving].compactMap { $0 }.max() ?? watchingSince
    }

    /// Standing on the pitch is what a goalkeeper does.
    private func isOnField(_ evidence: Evidence) -> Bool {
        guard let field = evidence.field else { return false }
        let recent = recent(evidence, 5 * 60).filter { $0.horizontalAccuracy <= 20 }
        let projector = FieldProjector(rectangle: field)
        return !recent.isEmpty && recent.filter { projector.isOnField($0.coordinate, marginMeters: 0) }.count * 3 >= recent.count
    }

    private func isStill(_ evidence: Evidence) -> Bool {
        let recent = recent(evidence, evidence.longestBreak)
        return recent.filter { $0.speedMetersPerSecond >= 0.8 }.count * 20 < max(recent.count, 1)
    }

    private func recent(_ evidence: Evidence, _ window: TimeInterval) -> ArraySlice<TrackPoint> {
        let from = evidence.now.addingTimeInterval(-window)
        return evidence.track[(evidence.track.lastIndex { $0.timestamp < from }.map { $0 + 1 } ?? 0)...]
    }

    /// A heart at rest for half an hour: lower than nearly all of the session before it, well short
    /// of working, and never once climbing. A sit-out between games is shorter, so some of the half
    /// hour would be play. Nil when there isn't the heart rate to say.
    private mutating func isResting(_ evidence: Evidence) -> Bool? {
        let window = Array(evidence.heartRate.suffix(while: { $0.date > evidence.now.addingTimeInterval(-Self.restingWindow) }))
        guard let first = window.first, let last = window.last, evidence.now.timeIntervalSince(last.date) < 120 else {
            return nil
        }
        if let restingBelow {
            // Known to be resting: until it's been up for a minute or so.
            let latest = window.suffix(while: { $0.date > evidence.now.addingTimeInterval(-120) }).map(\.bpm)
            if median(latest) < restingBelow { return true }
            self.restingBelow = nil
            return false
        }
        let before = evidence.heartRate.dropLast(window.count).map(\.bpm)
        let spacing = Self.restingWindow / Double(window.count)
        guard spacing <= 15, first.date.timeIntervalSince(evidence.now) < -Self.restingWindow + 120 else { return nil }
        guard before.count >= 120 else { return false }
        let rates = window.map(\.bpm)
        // A little over: after a relaunch at home, some of what came before was rest too.
        let resting = min(percentile(before, 0.2) + 3, 0.72 * percentile(before, 0.8))
        guard median(rates) < resting, percentile(rates, 0.95) < median(before), !Self.climbs(window) else { return false }
        restingBelow = resting
        return true
    }

    /// Up more than fifteen beats in a minute: somebody started running.
    private static func climbs(_ samples: [HeartRateSample]) -> Bool {
        var oldest = samples.startIndex
        for index in samples.indices {
            while samples[index].date.timeIntervalSince(samples[oldest].date) > 60 { oldest += 1 }
            if samples[index].bpm - (samples[oldest...index].map(\.bpm).min() ?? samples[index].bpm) > 15 { return true }
        }
        return false
    }
}

private extension Array {
    /// The elements at the end that all satisfy `predicate`.
    func suffix(while predicate: (Element) -> Bool) -> ArraySlice<Element> {
        self[(lastIndex { !predicate($0) }.map { $0 + 1 } ?? 0)...]
    }
}
