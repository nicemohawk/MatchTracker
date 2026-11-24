import Foundation

// MARK: - Editing a match record

public extension MatchRecord {
    /// When the match was played: the recording, cut to the trim.
    func played(within recorded: DateInterval) -> DateInterval {
        let start = max(trimmedStart ?? recorded.start, recorded.start)
        let end = min(trimmedEnd ?? recorded.end, recorded.end)
        return start < end ? DateInterval(start: start, end: end) : recorded
    }

    mutating func add(_ event: MatchEvent) {
        events.append(event)
        events.sort { $0.date < $1.date }
        raiseFinalScore()
    }

    /// More goals than the result said means there's one the result missed.
    private mutating func raiseFinalScore() {
        guard let final = finalScore, let logged = loggedScore else { return }
        finalScore = FinalScore(us: max(final.us, logged.us), them: max(final.them, logged.them),
                                mine: max(final.mine, logged.mine))
    }

    /// Change an event's details; nil leaves one alone, and an empty note clears it. An edited
    /// event is the wearer's word from then on.
    mutating func setEvent(_ id: UUID, kind: MatchEventKind? = nil, date: Date? = nil, note: String? = nil) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].kind = kind ?? events[index].kind
        events[index].date = date ?? events[index].date
        if let note { events[index].note = note.isEmpty ? nil : note }
        events[index].source = .manual
        events.sort { $0.date < $1.date }
        raiseFinalScore()
    }

    /// The removed event, to hand back to `add` on undo.
    @discardableResult
    mutating func removeEvent(_ id: UUID) -> MatchEvent? {
        events.firstIndex { $0.id == id }.map { events.remove(at: $0) }
    }

    /// The watch's copy of a match, sent again, with what has been said about it on the phone since.
    func keepingEdits(from existing: MatchRecord) -> MatchRecord {
        var merged = self
        merged.opponent = existing.opponent ?? opponent
        merged.notes = existing.notes ?? notes
        merged.trimmedStart = existing.trimmedStart ?? trimmedStart
        merged.trimmedEnd = existing.trimmedEnd ?? trimmedEnd
        merged.flipsAttack = existing.flipsAttack ?? flipsAttack
        merged.reportedPositions = existing.reportedPositions ?? reportedPositions
        merged.format = existing.format ?? format
        merged.fieldID = existing.fieldID ?? fieldID
        merged.finalScore = existing.finalScore ?? finalScore
        merged.track = track ?? existing.track
        merged.headings = headings ?? existing.headings
        merged.motion = motion ?? existing.motion
        merged.endDate = endDate ?? existing.endDate
        merged.startedOnPhone = existing.startedOnPhone == true ? startedOnPhone : nil
        if existing.detection != nil, existing.startedOnPhone != true {
            // Opened on the phone, so its events are the watch's with everything done to them since.
            merged.detection = existing.detection
            merged.events = existing.events
        } else {
            let edited = existing.events.filter { $0.source == .manual }
            let editedIDs = Set(edited.map(\.id))
            merged.events = (events.filter { !editedIDs.contains($0.id) } + edited).sorted { $0.date < $1.date }
        }
        return merged
    }

    /// Swap the automatic subs and periods for what today's detectors find, once per detector
    /// version. Manual events are never touched, and a match with manual subs gets no others.
    mutating func redetectEvents(track: [TrackPoint], projector: FieldProjector, halftime: DateInterval?,
                                 heartRate: [HeartRateSample] = []) {
        guard (detection ?? 0) < Self.currentDetection, !track.isEmpty else { return }
        detection = Self.currentDetection
        events.removeAll {
            $0.source == .automatic && [.subIn, .subOut, .periodStart, .periodEnd].contains($0.kind)
        }
        if !events.contains(where: { $0.kind == .subIn || $0.kind == .subOut }) {
            events += AutoSubDetector.detectEvents(track: track, projector: projector,
                                                   existingEvents: events, halftime: halftime, heartRate: heartRate,
                                                   motion: motion)
        }
        if let halftime, !events.contains(where: { $0.kind == .periodStart || $0.kind == .periodEnd }) {
            events += [MatchEvent(kind: .periodEnd, date: halftime.start, source: .automatic),
                       MatchEvent(kind: .periodStart, date: halftime.end, source: .automatic)]
        }
        events.sort { $0.date < $1.date }
    }
}

// MARK: - Trim suggestion

public enum TrimAdvisor {
    /// A recording that outlives the last movement by less than this was probably just slow to end.
    public static let patience: TimeInterval = 20 * 60
    private static let binSeconds = 30.0
    private static let minimumMatch: TimeInterval = 5 * 60

    /// When a recording left running should end, or nil when it ended about when play did.
    /// With a field, only movement around it counts, so the drive home isn't play.
    public static func suggestedEnd(recorded: DateInterval, track: [TrackPoint],
                                    heartRate: [HeartRateSample], field: OrientedRectangle?) -> Date? {
        guard let last = lastMovement(recorded: recorded, track: track, field: field)
                ?? lastHeartbeat(recorded: recorded, heartRate: heartRate),
              last.timeIntervalSince(recorded.start) >= minimumMatch,
              recorded.end.timeIntervalSince(last) > patience else { return nil }
        return last.addingTimeInterval(60)
    }

    /// The end of the last half minute spent mostly moving, two in a row, at walking pace or better.
    private static func lastMovement(recorded: DateInterval, track: [TrackPoint], field: OrientedRectangle?) -> Date? {
        let projector = field.map(FieldProjector.init(rectangle:))
        let ordered = track.filter { recorded.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
        var bins: [Int: (moving: Double, samples: Double)] = [:]
        for (point, speed) in zip(ordered, rawPointSpeeds(ordered)) {
            let isMoving = speed >= 1 && speed <= SpeedThresholds.plausibleMaximum
                && projector?.isOnField(point.coordinate, marginMeters: 30) != false
            let bin = Int(point.timestamp.timeIntervalSince(recorded.start) / binSeconds)
            bins[bin, default: (0, 0)].moving += isMoving ? 1 : 0
            bins[bin, default: (0, 0)].samples += 1
        }
        let moving = Set(bins.filter { $0.value.moving >= 0.3 * $0.value.samples && $0.value.samples >= 3 }.keys)
        return moving.filter { moving.contains($0 - 1) }.max()
            .map { recorded.start.addingTimeInterval(Double($0 + 1) * binSeconds) }
    }

    /// Without a route: the last time heart rate was still being sampled every few seconds, as it
    /// is in a workout. The sparse samples of everyday wear say nothing.
    private static func lastHeartbeat(recorded: DateInterval, heartRate: [HeartRateSample]) -> Date? {
        let dates = heartRate.map(\.date).filter(recorded.contains).sorted()
        let frequent = dates.indices.dropFirst().filter { dates[$0].timeIntervalSince(dates[$0 - 1]) <= 15 }
        guard frequent.count >= 60 else { return nil }
        return frequent.last.map { dates[$0] }
    }
}

// MARK: - Duplicate workouts

/// The same match recorded twice: by this app and by another one, or written back by a service it
/// was shared to. The other app's workout is left alone, only not listed.
public struct WorkoutSpan: Sendable {
    public var id: UUID
    public var interval: DateInterval
    public var sourceIdentifier: String
    public var hasRecord: Bool

    public init(id: UUID, interval: DateInterval, sourceIdentifier: String, hasRecord: Bool) {
        self.id = id
        self.interval = interval
        self.sourceIdentifier = sourceIdentifier
        self.hasRecord = hasRecord
    }

    public static let ownSourcePrefix = "com.nicemohawk.MatchTracker"

    public var isOurs: Bool { sourceIdentifier.hasPrefix(Self.ownSourcePrefix) }

    /// Workouts another source's workout already covers.
    public static func duplicates(among spans: [WorkoutSpan]) -> Set<UUID> {
        func preference(_ span: WorkoutSpan) -> (Int, TimeInterval) {
            (span.isOurs ? 3 : span.hasRecord ? 2 : span.sourceIdentifier.hasPrefix("com.apple.") ? 1 : 0,
             span.interval.duration)
        }
        var dropped: Set<UUID> = []
        let ordered = spans.sorted { $0.interval.start < $1.interval.start }
        for (index, first) in ordered.enumerated() {
            for second in ordered[(index + 1)...] {
                guard second.interval.start < first.interval.end else { break }
                guard first.sourceIdentifier != second.sourceIdentifier, first.isOurs != second.isOurs || !first.isOurs,
                      let overlap = first.interval.intersection(with: second.interval) else { continue }
                let shorter = min(first.interval.duration, second.interval.duration)
                let longer = max(first.interval.duration, second.interval.duration)
                // A recording left running all day covers matches it isn't a copy of.
                guard overlap.duration >= 0.8 * shorter, longer <= 4 * shorter else { continue }
                dropped.insert(preference(first) >= preference(second) ? second.id : first.id)
            }
        }
        return dropped
    }
}
