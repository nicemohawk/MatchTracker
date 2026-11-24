import Foundation

// MARK: - Automatic substitution detection
//
// What coming off looks like, measured over years of one player's matches: minutes on end without a
// run, slow but seldom still (a third to half of a bench spell is spent pacing), somewhere along a
// touchline and as often just inside the drawn outline as outside it, with the heart rate falling
// twenty to fifty beats. On the pitch, gaps of a minute or two between runs are ordinary, the typical
// speed is a walk, and the heart rate stays up.
//
// No single one of those says "benched", so they're weighed together over the last two minutes by a
// two-state filter. Sideways distance is what counts, as a share of the pitch's width: goalkeepers
// live by the goal line, and on a narrow pitch everything is near a touchline. Manual events win.

public struct AutoSubDetectorConfiguration: Sendable {
    public var maximumFixAccuracy: Double           // ignore worse fixes, default 20
    public var manualOverrideCooldown: TimeInterval // auto suppressed after a manual sub event, default 300

    public init() {
        maximumFixAccuracy = 20
        manualOverrideCooldown = 300
    }
}

public final class AutoSubDetector {
    private static let binSeconds: TimeInterval = 5
    /// Mean speed over a bin that counts as running, m/s: whatever a player's liveliest tenth is, but
    /// no more than a jog and no less than a brisk walk. Not everyone's game has running in it.
    private static let runningSpeeds = 1.5...2.2
    private static let windowBins = 24          // two minutes
    private static let runWindowBins = 12       // one minute
    private static let heartRateMemory: TimeInterval = 600

    private struct Bin {
        var index: Int
        var speed: Double
        var edge: Double
        var isRun: Bool
    }

    private let projector: FieldProjector
    private let configuration: AutoSubDetectorConfiguration

    private var isOnPitch: Bool
    /// How much more likely benched than playing, as log odds.
    private var logOdds: Double
    private var start: Date?
    private var bins: [Bin] = []
    private var openBin: (index: Int, speeds: [Double], edges: [Double])?
    private var previousPoint: TrackPoint?
    private var lastRunBin: Int?
    /// Where running began again after a minute without any.
    private var runResumedBin: Int?
    private var playingSpeeds: [Double] = []
    private var runningSpeed = AutoSubDetector.runningSpeeds.upperBound
    private var heartRates: [(date: Date, value: Double)] = []
    private var suppressUntil: Date?
    private var lastManualDate: Date?
    public private(set) var motion = MotionCalibration()

    public init(projector: FieldProjector,
                configuration: AutoSubDetectorConfiguration = .init(),
                initiallyOnPitch: Bool = true) {
        self.projector = projector
        self.configuration = configuration
        isOnPitch = initiallyOnPitch
        logOdds = initiallyOnPitch ? -4 : 4
    }

    /// Feed one live sample; returns a confirmed sub, dated when the player last ran before coming
    /// off or first ran after coming on, or nil.
    /// `motion` adds running the GPS is too slow to see, once it's known what running looks like on
    /// this wrist.
    public func process(point: TrackPoint, heartRate: Double?, motion trace: MotionTrace? = nil) -> MatchEvent? {
        if let heartRate, heartRate > 0 { recordHeartRate(heartRate, at: point.timestamp) }
        guard point.horizontalAccuracy <= configuration.maximumFixAccuracy else { return nil }
        defer { previousPoint = point }

        let start = start ?? point.timestamp
        self.start = start
        let index = Int(point.timestamp.timeIntervalSince(start) / Self.binSeconds)
        let speed = speed(at: point)
        let edge = projector.sidewaysShare(point.coordinate)
        var event: MatchEvent?
        if let open = openBin, open.index != index {
            event = close(open, motion: trace)
            openBin = nil
        }
        if openBin == nil { openBin = (index, [], []) }
        openBin?.speeds.append(speed)
        openBin?.edges.append(edge)
        return event
    }

    private func close(_ open: (index: Int, speeds: [Double], edges: [Double]), motion trace: MotionTrace?) -> MatchEvent? {
        let speed = mean(open.speeds)
        readMotion(trace)
        let isRun = speed >= runningSpeed
        if isRun { recordRun(open.index) }
        if isOnPitch { playingSpeeds.append(speed) }
        let isDue = bins.last.map { $0.index / 2 != open.index / 2 } ?? false
        bins.append(Bin(index: open.index, speed: speed, edge: medianValue(open.edges), isRun: isRun))
        bins.removeAll { $0.index <= open.index - Self.windowBins }
        return isDue ? evaluate(at: open.index) : nil
    }

    /// The wrist's reading for the bin before, which is the newest sure to be in.
    private func readMotion(_ trace: MotionTrace?) {
        guard let previous = bins.indices.last, let level = trace?.level(at: date(ofBin: bins[previous].index)
            .addingTimeInterval(Self.binSeconds / 2)) else { return }
        motion.learn(level: level, speed: bins[previous].speed)
        guard !bins[previous].isRun, motion.isRunning(level) else { return }
        bins[previous].isRun = true
        recordRun(bins[previous].index)
    }

    private func recordRun(_ index: Int) {
        if index - (lastRunBin ?? 0) >= Self.runWindowBins { runResumedBin = index }
        lastRunBin = max(index, lastRunBin ?? index)
    }

    /// Every ten seconds, weigh the last two minutes.
    private func evaluate(at index: Int) -> MatchEvent? {
        let lastMinute = bins.filter { $0.index > index - Self.runWindowBins }
        guard bins.count >= 8, lastMinute.count >= 3 else { return nil }
        let now = date(ofBin: index + 1)
        if playingSpeeds.count >= 60 {
            let liveliest = playingSpeeds.sorted()[playingSpeeds.count * 9 / 10]
            runningSpeed = min(max(liveliest, Self.runningSpeeds.lowerBound), Self.runningSpeeds.upperBound)
        }

        // Either way can happen at any moment: off every forty minutes or so, back on every twelve.
        let chance = 1 / (1 + exp(-logOdds))
        let carried = chance * (1 - 1 / 72.0) + (1 - chance) / 240.0
        logOdds = log(carried / (1 - carried)) + evidence(at: index, lastMinute: lastMinute, now: now) / 6
        logOdds = min(max(logOdds, -5), 4)

        // The wearer has just said. What it looks like can wait until that's had time to be true.
        if let suppressUntil, now < suppressUntil {
            logOdds = isOnPitch ? min(logOdds, 0) : max(logOdds, 0)
            return nil
        }
        if isOnPitch, logOdds > 2 {
            isOnPitch = false
            runResumedBin = nil
            return event(.subOut, at: date(ofBin: (lastRunBin ?? -1) + 1))
        }
        if !isOnPitch, logOdds < -1.5 {
            isOnPitch = true
            return event(.subIn, at: date(ofBin: runResumedBin ?? index))
        }
        return nil
    }

    /// Positive for the bench. Each weight is how much likelier that reading was off than on.
    private func evidence(at index: Int, lastMinute: [Bin], now: Date) -> Double {
        let sinceRun = Double(index - (lastRunBin ?? 0)) * Self.binSeconds
        var evidence = Self.weight(sinceRun, below: [20, 60, 120, 180, 300], [-1.4, -0.7, -0.2, 0.6, 1.4, 2])
        evidence += Self.weight(medianValue(bins.map(\.speed)), below: [0.4, 0.7, 1, 1.3], [1, 0.5, -0.1, -0.6, -1.2])
        evidence += Self.weight(medianValue(bins.map(\.edge)), below: [-0.45, -0.3, -0.2, -0.1, 0, 0.12],
                                [-2.6, -1.8, -0.9, 0, 0.8, 1.4, 2])
        evidence += Self.weight(Double(lastMinute.filter(\.isRun).count), below: [1, 2, 3], [0.2, -0.4, -1.2, -2.4])
        if let change = heartRateChange(at: now) {
            evidence += Self.weight(change, below: [-35, -25, -18, -12, -6], [2, 1.3, 0.7, 0, -0.8, -1.4])
        }
        return evidence
    }

    private static func weight(_ value: Double, below edges: [Double], _ weights: [Double]) -> Double {
        weights[edges.firstIndex { value < $0 } ?? edges.count]
    }

    /// Manual events win: re-sync detector state to the logged event and suppress auto output for
    /// the cooldown. Non-sub events are irrelevant to substitution tracking and ignored.
    public func recordManualEvent(_ event: MatchEvent) {
        switch event.kind {
        case .subIn: (isOnPitch, logOdds) = (true, -4)
        case .subOut: (isOnPitch, logOdds) = (false, 4)
        default: return
        }
        lastManualDate = event.date
        runResumedBin = nil
        suppressUntil = event.date.addingTimeInterval(configuration.manualOverrideCooldown)
    }

    /// Never dated before what the wearer said: that settled everything up to it.
    private func event(_ kind: MatchEventKind, at date: Date) -> MatchEvent {
        MatchEvent(kind: kind, date: max(date, lastManualDate ?? date), source: .automatic)
    }

    // MARK: Readings

    private func date(ofBin index: Int) -> Date {
        (start ?? .distantPast).addingTimeInterval(Double(index) * Self.binSeconds)
    }

    private func speed(at point: TrackPoint) -> Double {
        if point.speedMetersPerSecond >= 0 { return point.speedMetersPerSecond }
        guard let previousPoint else { return 0 }
        let seconds = point.timestamp.timeIntervalSince(previousPoint.timestamp)
        return seconds > 0 ? min(haversineMeters(previousPoint.coordinate, point.coordinate) / seconds, 10) : 0
    }

    private func recordHeartRate(_ value: Double, at date: Date) {
        guard heartRates.last.map({ date > $0.date }) ?? true else { return }
        heartRates.append((date, value))
        heartRates.removeAll { $0.date < date.addingTimeInterval(-Self.heartRateMemory) }
    }

    /// The last half minute against what playing has lately taken. Nil until that's known.
    private func heartRateChange(at date: Date) -> Double? {
        let recent = heartRates.filter { $0.date >= date.addingTimeInterval(-30) }.map(\.value)
        guard recent.count >= 2, let first = heartRates.first, date.timeIntervalSince(first.date) >= 60 else { return nil }
        let sorted = heartRates.map(\.value).sorted()
        return mean(recent) - sorted[min(sorted.count - 1, sorted.count * 3 / 4)]
    }

    // MARK: A finished match

    /// Every transition in a complete track: a replay through a fresh instance, respecting any
    /// existing manual sub events (their state + cooldown window). Sorted by date.
    static func transitions(track: [TrackPoint], projector: FieldProjector, existingEvents: [MatchEvent],
                            heartRate: [HeartRateSample] = [], motion: MotionTrace? = nil,
                            configuration: AutoSubDetectorConfiguration = .init()) -> [MatchEvent] {
        let orderedTrack = track.sorted { $0.timestamp < $1.timestamp }
        let orderedHeartRate = heartRate.sorted { $0.date < $1.date }
        let manualSubs = existingEvents
            .filter { $0.kind == .subIn || $0.kind == .subOut }
            .sorted { $0.date < $1.date }

        // Start on the pitch unless the first existing sub event is the wearer coming on.
        let initiallyOnPitch = !(manualSubs.first?.kind == .subIn)
        let detector = AutoSubDetector(projector: projector,
                                       configuration: configuration,
                                       initiallyOnPitch: initiallyOnPitch)

        var manualIndex = 0, heartRateIndex = 0
        var newEvents: [MatchEvent] = []
        for point in orderedTrack {
            // Apply any manual sub events whose time has arrived, so we honour their state and
            // suppress auto output inside their cooldown window.
            while manualIndex < manualSubs.count, manualSubs[manualIndex].date <= point.timestamp {
                detector.recordManualEvent(manualSubs[manualIndex])
                manualIndex += 1
            }
            while heartRateIndex < orderedHeartRate.count, orderedHeartRate[heartRateIndex].date <= point.timestamp {
                detector.recordHeartRate(orderedHeartRate[heartRateIndex].bpm, at: orderedHeartRate[heartRateIndex].date)
                heartRateIndex += 1
            }
            if let event = detector.process(point: point, heartRate: nil, motion: motion) {
                newEvents.append(event)
            }
        }
        return withoutSpellsTheHeartDenies(newEvents.sorted { $0.date < $1.date }, heartRate: orderedHeartRate)
    }

    /// A spell off during which the heart rate never came down was a quiet spell on.
    private static func withoutSpellsTheHeartDenies(_ events: [MatchEvent], heartRate: [HeartRateSample]) -> [MatchEvent] {
        guard let end = heartRate.last?.date else { return events }
        func average(_ from: Date, _ to: Date) -> Double? {
            let values = heartRate.filter { $0.date >= from && $0.date < to }.map(\.bpm)
            return values.count >= 4 ? mean(values) : nil
        }
        var kept: [MatchEvent] = []
        var index = 0
        while index < events.count {
            let off = events[index]
            index += 1
            guard off.kind == .subOut else {
                kept.append(off)
                continue
            }
            let next = index < events.count ? events[index] : nil
            let back = next?.kind == .subIn ? next : nil
            index += back == nil ? 0 : 1
            if let before = average(off.date.addingTimeInterval(-120), off.date),
               let during = average(off.date.addingTimeInterval(60), next?.date ?? end),
               during > before - 8 { continue }
            kept.append(off)
            if let back { kept.append(back) }
        }
        return kept
    }

    /// The substitutions in a finished match worth putting in its timeline. Being off the pitch at
    /// halftime, before kickoff or after the final whistle isn't a substitution, and a track that
    /// is mostly off the pitch is on the wrong pitch.
    public static func detectEvents(track: [TrackPoint], projector: FieldProjector,
                                    existingEvents: [MatchEvent], halftime: DateInterval? = nil,
                                    heartRate: [HeartRateSample] = [], motion: MotionTrace? = nil,
                                    configuration: AutoSubDetectorConfiguration = .init()) -> [MatchEvent] {
        let accurate = track.filter { $0.horizontalAccuracy <= configuration.maximumFixAccuracy }
        let inside = accurate.filter {
            projector.isOnField($0.coordinate, marginMeters: 5)
        }
        guard let start = track.map(\.timestamp).min(), let end = track.map(\.timestamp).max(),
              inside.count * 2 >= accurate.count else { return [] }

        let events = transitions(track: track, projector: projector,
                                 existingEvents: existingEvents, heartRate: heartRate, motion: motion,
                                 configuration: configuration)
        return substitutions(in: events, start: start, end: end, halftime: halftime)
    }

    /// Those of the spells off that are substitutions. Other kinds of event pass through.
    static func substitutions(in events: [MatchEvent], start: Date, end: Date, halftime: DateInterval?) -> [MatchEvent] {
        var kept: [MatchEvent] = []
        var index = 0
        while index < events.count {
            let event = events[index]
            guard event.kind == .subOut else {
                kept.append(event)
                index += 1
                continue
            }
            let next = index + 1 < events.count ? events[index + 1] : nil
            let back = next?.kind == .subIn ? next : nil
            index += back == nil ? 1 : 2

            let isHalftime = halftime.map { event.date < $0.end && (back?.date ?? end) > $0.start } ?? false
            let isAfterTheWhistle = back == nil && end.timeIntervalSince(event.date) < edgeOfMatch
            if isHalftime || isAfterTheWhistle { continue }
            if event.date.timeIntervalSince(start) < 120 {
                // Off from the start: on the bench if it lasted, still arriving if it didn't.
                if let back, back.date.timeIntervalSince(start) >= edgeOfMatch { kept.append(back) }
                continue
            }
            kept.append(event)
            if let back { kept.append(back) }
        }
        return kept
    }

    /// How close to the start or end of a recording being off the pitch means nothing.
    private static let edgeOfMatch: TimeInterval = 600
}

private func medianValue(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
}
