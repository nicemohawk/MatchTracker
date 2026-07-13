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
    public var exitDwell: TimeInterval            // continuous off-pitch time before subOut, default 30
    public var enterDwell: TimeInterval           // continuous on-pitch time before subIn, default 15
    public var maximumFixAccuracy: Double         // ignore worse fixes for boundary calls, default 20
    public var manualOverrideCooldown: TimeInterval // auto suppressed after a manual sub event, default 60

    public init() {
        exitDistanceMeters = 5.0
        exitDwell = 30
        enterDwell = 15
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
    public func process(point: TrackPoint, heartRate: Double?) -> MatchEvent? {
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
            if isClearlyOff {
                state = .candidateOff(since: point.timestamp)
            }
            return nil

        case .candidateOff(let since):
            if isInside {
                state = .onPitch                       // stepped back in before the dwell elapsed
                return nil
            }
            // A clearly-off sample always counts toward the dwell; an ambiguous sample counts only
            // when HR is clearly falling. Ambiguous-neutral samples hold the candidate open.
            let countsTowardExit = isClearlyOff || (isAmbiguous && heartRateFalling)
            if countsTowardExit, point.timestamp.timeIntervalSince(since) >= configuration.exitDwell {
                state = .offPitch
                return emit(.subOut, at: since, detectedAt: point.timestamp)
            }
            return nil

        case .offPitch:
            if isInside {
                state = .candidateOn(since: point.timestamp)
            }
            return nil

        case .candidateOn(let since):
            if isInside {
                if point.timestamp.timeIntervalSince(since) >= configuration.enterDwell {
                    state = .onPitch
                    return emit(.subIn, at: since, detectedAt: point.timestamp)
                }
                return nil
            }
            // Re-entry requires being continuously inside the touchline proper; any sample back
            // outside (ambiguous or clearly off) cancels the pending sub-in.
            state = .offPitch
            return nil
        }
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

    /// Offline pass over a complete track (iOS post-match reconciliation for matches with a
    /// resolved field and no manual sub events). Replays the track through a fresh instance,
    /// respecting any existing manual sub events (their state + cooldown window), and returns only
    /// the new automatic events, sorted by date.
    public static func detectEvents(track: [TrackPoint], projector: FieldProjector,
                                    existingEvents: [MatchEvent],
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
            if let event = detector.process(point: point, heartRate: nil) {
                newEvents.append(event)
            }
        }
        return newEvents.sorted { $0.date < $1.date }
    }

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
