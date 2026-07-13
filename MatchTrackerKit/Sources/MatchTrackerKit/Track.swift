import Foundation

// MARK: - Track & events

public struct TrackPoint: Codable, Hashable, Sendable {
    public var coordinate: Coordinate2D
    public var timestamp: Date
    public var speedMetersPerSecond: Double   // -1 if invalid
    public var courseDegrees: Double          // -1 if invalid
    public var horizontalAccuracy: Double

    public init(coordinate: Coordinate2D, timestamp: Date, speedMetersPerSecond: Double, courseDegrees: Double, horizontalAccuracy: Double) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.speedMetersPerSecond = speedMetersPerSecond
        self.courseDegrees = courseDegrees
        self.horizontalAccuracy = horizontalAccuracy
    }
}

public enum MatchEventKind: String, Codable, CaseIterable, Sendable {
    case matchStart, matchEnd
    case periodStart, periodEnd
    case subIn, subOut                 // player enters/leaves the pitch
    case goalForUs = "goalFor", goalAgainstUs = "goalAgainst"
    case goalMine                      // wearer scored
    case assist
    case flag                          // generic "something happened" marker for post-game review
}

public struct MatchEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: MatchEventKind
    public var date: Date
    public var note: String?

    public init(id: UUID = UUID(), kind: MatchEventKind, date: Date, note: String? = nil) {
        self.id = id
        self.kind = kind
        self.date = date
        self.note = note
    }
}

/// Watch-side record of one match; JSON codable, transferred watch -> phone.
public struct MatchRecord: Codable, Identifiable, Sendable {
    public var id: UUID                 // == HKWorkout.uuid when available
    public var startDate: Date
    public var endDate: Date?
    public var fieldID: UUID?
    public var events: [MatchEvent]
    public var teamCode: String?

    public init(id: UUID, startDate: Date, endDate: Date?, fieldID: UUID?, events: [MatchEvent], teamCode: String?) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.fieldID = fieldID
        self.events = events
        self.teamCode = teamCode
    }
}

public enum SubstitutionTracker {
    /// Intervals the wearer was on the pitch. Match starts "on" unless events start with subIn.
    public static func playingIntervals(events: [MatchEvent], matchStart: Date, matchEnd: Date) -> [DateInterval] {
        // STUB: whole match counts as on-pitch, ignoring subIn/subOut for now.
        guard matchEnd > matchStart else { return [] }
        return [DateInterval(start: matchStart, end: matchEnd)]
    }

    public static func timeOnPitch(events: [MatchEvent], matchStart: Date, matchEnd: Date) -> TimeInterval {
        // STUB: sum of playing intervals.
        playingIntervals(events: events, matchStart: matchStart, matchEnd: matchEnd)
            .reduce(0) { $0 + $1.duration }
    }
}
