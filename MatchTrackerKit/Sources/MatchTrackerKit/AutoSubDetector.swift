import Foundation

// MARK: - Automatic substitution detection
//
// Geometry-first by design. The only positive signal for "benched" is sustained presence
// OUTSIDE the touchline — never low movement. Keepers and centre-backs can stand still for long
// stretches while very much in the game, so a stationary player inside the pitch is always "on".
// Heart-rate trend is a *tiebreaker* for fixes hovering in the ambiguous boundary band and can
// only ever add evidence toward a pending sub-out; it never vetoes geometry and never forces a
// transition on its own (a substitute warming up along the sideline has high HR yet is off).
// Manual events win: a logged sub re-syncs the state machine and mutes auto output for a cooldown.

public struct AutoSubDetectorConfiguration: Sendable {
    public var exitDistanceMeters: Double         // beyond-touchline distance that counts as off-pitch, default 5.0
    /// Off-pitch time before subOut, and on-pitch time before subIn. These are also the shortest
    /// bench spell and shortest stint that can be detected: anything briefer is fetching a ball,
    /// a drink, or a wandering fix. Events are still dated at the crossing.
    public var exitDwell: TimeInterval            // default 150
    public var enterDwell: TimeInterval           // default 120
    /// The same two when the wrist agrees: still for a minute off the pitch, or running on it.
    public var stillExitDwell: TimeInterval       // default 75
    public var playingEnterDwell: TimeInterval    // default 60
    /// Share of contrary samples a pending transition survives; GPS strays at the touchline.
    public var contradictionTolerance: Double     // default 0.2
    public var maximumFixAccuracy: Double         // ignore worse fixes for boundary calls, default 20
    public var manualOverrideCooldown: TimeInterval // auto suppressed after a manual sub event, default 60

    public init() {
        exitDistanceMeters = 5.0
        exitDwell = 150
        enterDwell = 120
        stillExitDwell = 75
        playingEnterDwell = 60
        contradictionTolerance = 0.2
        maximumFixAccuracy = 20
        manualOverrideCooldown = 60
    }
}

public final class AutoSubDetector {
    /// Detector lifecycle. `candidate*` states hold a provisional transition whose start date is
    /// the moment the wearer first crossed the threshold — that's the date the emitted event
    /// carries, not the (later) moment the dwell requirement is satisfied.
    private enum State {
        case onPitch
        case candidateOff(since: Date)
        case offPitch
        case candidateOn(since: Date)
    }

    private let projector: FieldProjector
    private let configuration: AutoSubDetectorConfiguration
    private var state: State

    /// Samples seen, and how many contradicted it, since the pending transition began.
    private var candidateSamples = 0
    private var contradictions = 0
    private static let minimumSamplesToContradict = 10

    /// Auto emissions are swallowed until this instant after a manual sub event (manual wins).
    private var suppressUntil: Date?

    /// Rolling heart-rate samples used only for the ambiguous-band tiebreak.
    private var heartRateSamples: [(date: Date, value: Double)] = []
    private let heartRatePeakWindow: TimeInterval = 180   // "rolling 3-min peak"

    public init(projector: FieldProjector,
                configuration: AutoSubDetectorConfiguration = .init(),
                initiallyOnPitch: Bool = true) {
        self.projector = projector
        self.configuration = configuration
        self.state = initiallyOnPitch ? .onPitch : .offPitch
    }

    /// Feed one live sample; returns a confirmed auto sub event (dated at the transition moment,
    /// not the detection moment) or nil. `heartRate` is optional and used only for tiebreaks.
    /// `motion` is the wrist's last minute: nobody playing hard is benched, nobody sitting still is on.
    public func process(point: TrackPoint, heartRate: Double?, motion: MotionReading? = nil) -> MatchEvent? {
        // Blind fix: too inaccurate to make a boundary call. Don't change state and don't reset a
        // pending candidate — an uncertain sample must neither confirm nor contradict geometry.
        guard point.horizontalAccuracy <= configuration.maximumFixAccuracy else { return nil }

        if let heartRate { recordHeartRate(heartRate, at: point.timestamp) }

        let distanceOutside = projector.distanceOutsideMeters(point.coordinate)
        let isInside = distanceOutside <= 0
        let isClearlyOff = distanceOutside > configuration.exitDistanceMeters
        // Ambiguous band: outside the touchline but within the exit distance. On its own it holds
        // the current state; only a clearly-falling HR lets it advance a pending sub-out.
        let isAmbiguous = distanceOutside > 0 && !isClearlyOff
        let heartRateFalling = isHeartRateClearlyFalling(current: heartRate)

        switch state {
        case .onPitch:
            // A bench is often nearer the line than GPS can tell; sitting still settles it.
            if isClearlyOff || (isAmbiguous && motion == .still) { begin(.candidateOff(since: point.timestamp)) }
            return nil

        case .candidateOff(let since):
            if isContradicted(by: isInside) {
                state = .onPitch                       // stepped back in before the dwell elapsed
                return nil
            }
            // Running hard beside the pitch: the outline is off, or a substitute is warming up.
            if motion == .playing {
                state = .candidateOff(since: point.timestamp)
                return nil
            }
            // A clearly-off sample always counts toward the dwell; an ambiguous sample counts only
            // when HR is clearly falling or the wrist is still. Ambiguous-neutral samples hold the
            // candidate open.
            let countsTowardExit = isClearlyOff || (isAmbiguous && (heartRateFalling || motion == .still))
            let dwell = motion == .still ? configuration.stillExitDwell : configuration.exitDwell
            if countsTowardExit, point.timestamp.timeIntervalSince(since) >= dwell {
                state = .offPitch
                return emit(.subOut, at: since, detectedAt: point.timestamp)
            }
            return nil

        case .offPitch:
            if isInside { begin(.candidateOn(since: point.timestamp)) }
            return nil

        case .candidateOn(let since):
            if isContradicted(by: isClearlyOff) {
                state = .offPitch
                return nil
            }
            // Sitting by the touchline with GPS a few meters out.
            if motion == .still {
                state = .candidateOn(since: point.timestamp)
                return nil
            }
            let dwell = motion == .playing ? configuration.playingEnterDwell : configuration.enterDwell
            if isInside, point.timestamp.timeIntervalSince(since) >= dwell {
                state = .onPitch
                return emit(.subIn, at: since, detectedAt: point.timestamp)
            }
            return nil
        }
    }

    private func begin(_ candidate: State) {
        state = candidate
        candidateSamples = 1
        contradictions = 0
    }

    private func isContradicted(by isContrary: Bool) -> Bool {
        candidateSamples += 1
        if isContrary { contradictions += 1 }
        return candidateSamples >= Self.minimumSamplesToContradict
            && Double(contradictions) > configuration.contradictionTolerance * Double(candidateSamples)
    }

    /// Manual events win: re-sync detector state to the logged event and suppress auto output for
    /// the cooldown. Non-sub events are irrelevant to substitution tracking and ignored.
    public func recordManualEvent(_ event: MatchEvent) {
        switch event.kind {
        case .subIn: state = .onPitch
        case .subOut: state = .offPitch
        default: return
        }
        suppressUntil = event.date.addingTimeInterval(configuration.manualOverrideCooldown)
    }

    /// Every transition in a complete track: a replay through a fresh instance, respecting any
    /// existing manual sub events (their state + cooldown window). Sorted by date.
    static func transitions(track: [TrackPoint], projector: FieldProjector, existingEvents: [MatchEvent],
                            motion: MotionTrace? = nil,
                            configuration: AutoSubDetectorConfiguration) -> [MatchEvent] {
        let orderedTrack = track.sorted { $0.timestamp < $1.timestamp }
        let manualSubs = existingEvents
            .filter { $0.kind == .subIn || $0.kind == .subOut }
            .sorted { $0.date < $1.date }

        // Start on the pitch unless the first existing sub event is the wearer coming on.
        let initiallyOnPitch = !(manualSubs.first?.kind == .subIn)
        let detector = AutoSubDetector(projector: projector,
                                       configuration: configuration,
                                       initiallyOnPitch: initiallyOnPitch)

        var manualIndex = 0
        var newEvents: [MatchEvent] = []
        for point in orderedTrack {
            // Apply any manual sub events whose time has arrived, so we honour their state and
            // suppress auto output inside their cooldown window.
            while manualIndex < manualSubs.count, manualSubs[manualIndex].date <= point.timestamp {
                detector.recordManualEvent(manualSubs[manualIndex])
                manualIndex += 1
            }
            if let event = detector.process(point: point, heartRate: nil,
                                            motion: motion?.reading(at: point.timestamp)) {
                newEvents.append(event)
            }
        }
        return newEvents.sorted { $0.date < $1.date }
    }

    /// The substitutions in a finished match worth putting in its timeline. Being off the pitch at
    /// halftime, before kickoff or after the final whistle isn't a substitution, and a track that
    /// is mostly off the pitch is on the wrong pitch.
    public static func detectEvents(track: [TrackPoint], projector: FieldProjector,
                                    existingEvents: [MatchEvent], halftime: DateInterval? = nil,
                                    motion: MotionTrace? = nil,
                                    configuration: AutoSubDetectorConfiguration = .init()) -> [MatchEvent] {
        let accurate = track.filter { $0.horizontalAccuracy <= configuration.maximumFixAccuracy }
        let inside = accurate.filter {
            projector.isOnField($0.coordinate, marginMeters: configuration.exitDistanceMeters)
        }
        guard let start = track.map(\.timestamp).min(), let end = track.map(\.timestamp).max(),
              inside.count * 2 >= accurate.count else { return [] }

        let events = transitions(track: track, projector: projector,
                                 existingEvents: existingEvents, motion: motion, configuration: configuration)
        var kept: [MatchEvent] = []
        var index = 0
        while index < events.count {
            let event = events[index]
            guard event.kind == .subOut else {
                kept.append(event)
                index += 1
                continue
            }
            let back = index + 1 < events.count ? events[index + 1] : nil
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

    // MARK: - Emission / heart-rate helpers

    private func emit(_ kind: MatchEventKind, at date: Date, detectedAt: Date) -> MatchEvent? {
        // Manual events win: swallow auto output inside the post-manual cooldown window.
        if let suppressUntil, detectedAt < suppressUntil { return nil }
        return MatchEvent(kind: kind, date: date, source: .automatic)
    }

    private func recordHeartRate(_ value: Double, at date: Date) {
        heartRateSamples.append((date, value))
        let cutoff = date.addingTimeInterval(-heartRatePeakWindow)
        heartRateSamples.removeAll { $0.date < cutoff }
    }

    /// A clearly-falling HR (current below 75% of the rolling 3-min peak) is the only condition
    /// under which an ambiguous-band sample counts toward a pending sub-out. Minimal by intent.
    private func isHeartRateClearlyFalling(current: Double?) -> Bool {
        guard let current, current > 0 else { return false }
        let peak = heartRateSamples.map(\.value).max() ?? current
        guard peak > 0 else { return false }
        return current < 0.75 * peak
    }
}
