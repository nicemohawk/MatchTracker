import Foundation

// MARK: - Track & events

public struct TrackPoint: Codable, Hashable, Sendable {
    /// GPS fixes worse than this horizontal accuracy (meters) are discarded before they reach
    /// the route/track. Shared by the watch recorder and field inference.
    public static let maximumUsableHorizontalAccuracy = 50.0

    /// Tighter gate for field training walks: the outline directly defines field geometry,
    /// so loose fixes distort the fitted rectangle more than they would a match track.
    public static let fieldTrainingHorizontalAccuracy = 20.0

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
    /// Intervals the wearer was on the pitch. The wearer starts "on" unless the first sub event
    /// is a subIn. Each subOut closes the current on-pitch interval; each subIn opens a new one.
    /// A trailing on-pitch stretch (a subIn with no matching subOut) runs to matchEnd. Malformed
    /// duplicates (subOut while already off, subIn while already on) are ignored.
    public static func playingIntervals(events: [MatchEvent], matchStart: Date, matchEnd: Date) -> [DateInterval] {
        guard matchEnd > matchStart else { return [] }

        let subEvents = events
            .filter { ($0.kind == .subIn || $0.kind == .subOut) && $0.date >= matchStart && $0.date <= matchEnd }
            .sorted { $0.date < $1.date }

        // Start on the pitch unless the very first substitution is the wearer coming on.
        var onPitch = !(subEvents.first?.kind == .subIn)
        var currentStart = matchStart
        var intervals: [DateInterval] = []

        for event in subEvents {
            switch event.kind {
            case .subOut where onPitch:
                if event.date > currentStart {
                    intervals.append(DateInterval(start: currentStart, end: event.date))
                }
                onPitch = false
            case .subIn where !onPitch:
                currentStart = event.date
                onPitch = true
            default:
                continue // duplicate / malformed event, ignore
            }
        }

        if onPitch && matchEnd > currentStart {
            intervals.append(DateInterval(start: currentStart, end: matchEnd))
        }
        return intervals
    }

    public static func timeOnPitch(events: [MatchEvent], matchStart: Date, matchEnd: Date) -> TimeInterval {
        playingIntervals(events: events, matchStart: matchStart, matchEnd: matchEnd)
            .reduce(0) { $0 + $1.duration }
    }
}
