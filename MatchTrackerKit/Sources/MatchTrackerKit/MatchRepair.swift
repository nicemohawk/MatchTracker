import Foundation

// MARK: - Editing a match record

public extension MatchRecord {
    /// When the match was played: the recording, cut to the trim.
    func played(within recorded: DateInterval) -> DateInterval {
        let start = max(trimmedStart ?? recorded.start, recorded.start)
        let end = min(trimmedEnd ?? recorded.end, recorded.end)
        return start < end ? DateInterval(start: start, end: end) : recorded
    }

    /// Leave out the way there and the way home, once, unless the wearer has said when it was played.
    /// - Returns: Whether anything was left out.
    @discardableResult
    mutating func trimJourneys(recorded: DateInterval, track: [TrackPoint], field: OrientedRectangle?) -> Bool {
        guard trimmedStart == nil, trimmedEnd == nil, keepsWholeRecording != true,
              let played = TrimAdvisor.atThePitch(recorded: recorded, track: track, field: field) else { return false }
        trimmedStart = played.start > recorded.start ? played.start : nil
        trimmedEnd = played.end < recorded.end ? played.end : nil
        trimmedAutomatically = true
        return true
    }

    mutating func add(_ event: MatchEvent) {
        events.append(event)
        events.sort { $0.date < $1.date }
        raiseFinalScore()
    }

    /// More goals than the result said means there's one the result missed.
    private mutating func raiseFinalScore() {
        if let said = myGoals { myGoals = max(said, events.filter { $0.kind == .goalMine }.count) }
        if let said = myAssists { myAssists = max(said, events.filter { $0.kind == .assist }.count) }
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
        let removed = events.firstIndex { $0.id == id }.map { events.remove(at: $0) }
        if let removed, removed.source == .automatic, removed.kind == .subOut || removed.kind == .subIn {
            rejectedSubOuts = (rejectedSubOuts ?? 0) + 1
        }
        return removed
    }

    /// The watch's copy of a match, sent again, with what has been said about it on the phone since.
    func keepingEdits(from existing: MatchRecord) -> MatchRecord {
        var merged = self
        merged.opponent = existing.opponent ?? opponent
        merged.notes = existing.notes ?? notes
        merged.trimmedStart = existing.trimmedStart ?? trimmedStart
        merged.trimmedEnd = existing.trimmedEnd ?? trimmedEnd
        merged.trimmedAutomatically = existing.trimmedAutomatically ?? trimmedAutomatically
        merged.keepsWholeRecording = existing.keepsWholeRecording ?? keepsWholeRecording
        merged.flipsAttack = existing.flipsAttack ?? flipsAttack
        merged.reportedPositions = existing.reportedPositions ?? reportedPositions
        merged.format = existing.format ?? format
        merged.fieldID = existing.fieldID ?? fieldID
        merged.finalScore = existing.finalScore ?? finalScore
        merged.games = existing.games ?? games
        merged.keepsScore = existing.keepsScore ?? keepsScore
        merged.myGoals = existing.myGoals ?? myGoals
        merged.myAssists = existing.myAssists ?? myAssists
        merged.reviewedAt = existing.reviewedAt ?? reviewedAt
        merged.track = track ?? existing.track
        merged.headings = headings ?? existing.headings
        merged.motion = motion ?? existing.motion
        if let rejected = [rejectedSubOuts, existing.rejectedSubOuts].compactMap({ $0 }).max() { merged.rejectedSubOuts = rejected }
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
    /// version. Manual events are never touched, and substitutions the wearer had a say in are only
    /// cleared of half-time and the walk off.
    mutating func redetectEvents(track: [TrackPoint], projector: FieldProjector, halftime: DateInterval?,
                                 heartRate: [HeartRateSample] = []) {
        guard (detection ?? 0) < Self.currentDetection, !track.isEmpty else { return }
        detection = Self.currentDetection
        let isSettled = hasSettledSubs
        events.removeAll { $0.source == .automatic && [.periodStart, .periodEnd].contains($0.kind) }
        if isSettled {
            let end = track.map(\.timestamp).max() ?? startDate, subs = events.filter { $0.kind == .subIn || $0.kind == .subOut }
            let kept = Set(AutoSubDetector.substitutions(in: subs, start: startDate, end: end, halftime: halftime).map(\.id))
            events.removeAll { $0.source == .automatic && ($0.kind == .subIn || $0.kind == .subOut) && !kept.contains($0.id) }
        } else {
            events.removeAll { $0.source == .automatic && ($0.kind == .subIn || $0.kind == .subOut) }
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

    // MARK: Coming and going

    /// Faster than anyone runs for this long is a vehicle.
    static let vehicleSpeed = 7.0
    private static let runningSpeeds = 2.2...6.5
    private static let vehicleDuration: TimeInterval = 20
    /// Farther from play than any bench, toilet or car park.
    private static let farMeters = 300.0

    /// The part of a recording spent at the pitch, when the rest was plainly getting there or going
    /// home: driven, or far away, and never back. Nil when there's nothing to leave out.
    public static func atThePitch(recorded: DateInterval, track: [TrackPoint], field: OrientedRectangle?) -> DateInterval? {
        let ordered = track.filter { recorded.contains($0.timestamp) && $0.horizontalAccuracy <= 50 }
            .sorted { $0.timestamp < $1.timestamp }
        guard let place = PlaceOfPlay(track: ordered, field: field) else { return nil }
        let near = ordered.indices.filter { place.isNear(ordered[$0].coordinate) }
        guard let first = near.first, let last = near.last else { return nil }

        var start = recorded.start, end = recorded.end
        if isJourney(ordered[..<first], from: place) { start = ordered[first].timestamp }
        if isJourney(ordered[(last + 1)...], from: place) {
            end = ordered[last].timestamp
            // Standing about and packing up came before the car.
            if let moving = lastMovement(recorded: DateInterval(start: start, end: max(end, start)), track: ordered, field: field) {
                end = min(end, moving.addingTimeInterval(60))
            }
        }
        guard start > recorded.start || end < recorded.end, end.timeIntervalSince(start) >= minimumMatch else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// Whether somebody still recording has left for good, judging by the last few minutes of fixes.
    public static func hasLeft(track: [TrackPoint], field: OrientedRectangle?) -> Bool {
        guard let place = PlaceOfPlay(track: track, field: field), let now = track.last?.timestamp,
              let lastNear = track.lastIndex(where: { place.isNear($0.coordinate) }) else { return false }
        let away = track[(lastNear + 1)...]
        return now.timeIntervalSince(track[lastNear].timestamp) >= 60 && isJourney(away, from: place)
    }

    /// How far past the pitch and what's around it the latest fix is. Nil when that isn't known.
    static func metersFromPlay(track: [TrackPoint], field: OrientedRectangle?) -> Double? {
        guard let last = track.last else { return nil }
        return PlaceOfPlay(track: track, field: field)?.distance(to: last.coordinate)
    }

    /// Whether somebody who left has been running about one place since: another pitch, not a way home.
    static func playsElsewhere(track: [TrackPoint], field: OrientedRectangle?) -> Bool {
        guard let place = PlaceOfPlay(track: track, field: field),
              let lastNear = track.lastIndex(where: { place.isNear($0.coordinate) }) else { return false }
        let running = track[(lastNear + 1)...].filter { runningSpeeds.contains($0.speedMetersPerSecond) }.map(\.coordinate)
        guard running.count >= 180 else { return false }
        let middle = Coordinate2D(latitude: median(running.map(\.latitude)), longitude: median(running.map(\.longitude)))
        return running.filter { haversineMeters($0, middle) <= 120 }.count >= 180
    }

    private static func isJourney(_ points: ArraySlice<TrackPoint>, from place: PlaceOfPlay) -> Bool {
        if points.contains(where: { place.distance(to: $0.coordinate) > farMeters }) { return true }
        var began: Date?, previous: Date?
        for point in points {
            if point.speedMetersPerSecond < vehicleSpeed || previous.map({ point.timestamp.timeIntervalSince($0) > 30 }) == true {
                began = nil
            }
            if point.speedMetersPerSecond >= vehicleSpeed {
                began = began ?? point.timestamp
                if let began, point.timestamp.timeIntervalSince(began) >= vehicleDuration { return true }
            }
            previous = point.timestamp
        }
        return false
    }

    /// The pitch and what's around it: a saved one, or else wherever the running was.
    private struct PlaceOfPlay {
        private let center: Coordinate2D
        private let radius: Double

        init?(track: [TrackPoint], field: OrientedRectangle?) {
            if let field {
                center = field.center
                radius = hypot(field.lengthMeters, field.widthMeters) / 2 + 100
                return
            }
            let running = track.filter { runningSpeeds.contains($0.speedMetersPerSecond) }.map(\.coordinate)
            guard running.count >= 60 else { return nil }
            let latitudes = running.map(\.latitude).sorted(), longitudes = running.map(\.longitude).sorted()
            center = Coordinate2D(latitude: latitudes[running.count / 2], longitude: longitudes[running.count / 2])
            radius = 160
        }

        func distance(to coordinate: Coordinate2D) -> Double { haversineMeters(center, coordinate) - radius }
        func isNear(_ coordinate: Coordinate2D) -> Bool { distance(to: coordinate) <= 0 }
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
