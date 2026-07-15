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
    // Referee / multi-sport kinds (surfaced per SportProfile.eventVocabulary; raw == case name).
    case yellowCard
    case redCard
    case foul
    case turnover
    case timeout
}

/// Whether an event was logged by the wearer (`manual`) or inferred by the app (`automatic`,
/// e.g. `AutoSubDetector`). Manual always wins during reconciliation.
public enum MatchEventSource: String, Codable, Sendable { case manual, automatic }

public struct MatchEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: MatchEventKind
    public var date: Date
    public var note: String?
    public var source: MatchEventSource   // decodeIfPresent, defaults .manual (wire compat)

    public init(id: UUID = UUID(), kind: MatchEventKind, date: Date, note: String? = nil, source: MatchEventSource = .manual) {
        self.id = id
        self.kind = kind
        self.date = date
        self.note = note
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, date, note, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(MatchEventKind.self, forKey: .kind)
        date = try container.decode(Date.self, forKey: .date)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        // Back-compat: records/payloads written before auto-detection carry no "source".
        source = try container.decodeIfPresent(MatchEventSource.self, forKey: .source) ?? .manual
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(source, forKey: .source)   // always present going forward
    }
}

/// A position the wearer reports having played, edited by hand on the match detail. Distinct from
/// the app's inferred `PositionEstimate`: this is ground truth the player supplied. `side` is
/// optional so a role with no meaningful side (e.g. a lone striker, or "I just played defense")
/// round-trips as a role-only entry.
public struct ReportedPosition: Codable, Sendable, Equatable, Hashable {
    public let role: PositionRole
    public let side: PositionSide?

    public init(role: PositionRole, side: PositionSide? = nil) {
        self.role = role
        self.side = side
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
    public var sportID: String?             // nil == soccer (SportProfile.id)
    public var headings: [HeadingSample]?   // optional device-heading samples for track fusion
    public var format: MatchFormat?         // nil ≡ .match (wire "format")
    /// Positions the wearer says they played, edited on the phone. `nil` means never edited (so the
    /// UI can distinguish "not set" from "set to empty"); synthesized Codable decodes it with
    /// `decodeIfPresent`, keeping records written before this field loading cleanly.
    public var reportedPositions: [ReportedPosition]?

    // Synthesized Codable: every added field is optional, so JSON written before they existed
    // still decodes cleanly (the keys are simply absent, `format` nil ≡ .match).
    public init(id: UUID, startDate: Date, endDate: Date?, fieldID: UUID?, events: [MatchEvent], teamCode: String?, sportID: String? = nil, headings: [HeadingSample]? = nil, format: MatchFormat? = nil, reportedPositions: [ReportedPosition]? = nil) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.fieldID = fieldID
        self.events = events
        self.teamCode = teamCode
        self.sportID = sportID
        self.headings = headings
        self.format = format
        self.reportedPositions = reportedPositions
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
