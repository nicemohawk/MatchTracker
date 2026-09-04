import Foundation

// MARK: - Teams, chat, formation (client side of the V2 backend endpoints)

/// A team the device belongs to. `SettingsStore` holds `[TeamMembership]`; a `MatchRecord`'s
/// `teamCode` picks which of these a match is uploaded against.
public struct TeamMembership: Codable, Hashable, Sendable, Identifiable {
    public var id: String { code }
    public var code: String
    public var name: String?
    /// Minors-privacy option: render this member as initials ("B. L.") everywhere their name would
    /// otherwise appear. The backend enforces it server-side; this flag mirrors that preference.
    public var displayInitialsOnly: Bool

    public init(code: String, name: String? = nil, displayInitialsOnly: Bool = false) {
        self.code = code
        self.name = name
        self.displayInitialsOnly = displayInitialsOnly
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case name
        case displayInitialsOnly = "initials_only"
    }
}

/// One team-chat comment on a match. Wire shape is snake_case per V2 §2.
public struct MatchComment: Codable, Identifiable, Sendable {
    public var id: UUID
    public var matchUUID: UUID
    public var author: String
    public var body: String
    public var postedAt: Date

    public init(id: UUID = UUID(), matchUUID: UUID, author: String, body: String, postedAt: Date = Date()) {
        self.id = id
        self.matchUUID = matchUUID
        self.author = author
        self.body = body
        self.postedAt = postedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case matchUUID = "match_uuid"
        case author
        case body
        case postedAt = "posted_at"
    }
}

/// One event from any teammate's match, as delivered by the unified team timeline
/// (`GET /teams/{code}/events`, V2 §11). The coach view coalesces every player's tagged events
/// into a single chronological feed and can attach a `coachLabel` to unlabeled ones.
///
/// `kind` is decoded tolerantly: the raw wire string is preserved in `kindRawValue` (so an
/// event kind this client build doesn't know still renders), and `kind` is the parsed
/// `MatchEventKind` when recognized, else nil. `coachLabel` is the coach's annotation and is
/// kept separate from the player's own `note` — the two render side by side, never overwriting.
public struct TeamEvent: Codable, Identifiable, Sendable {
    /// The event's own uuid (stable across the player's upload and the live relay).
    public var id: UUID
    public var playerName: String
    public var matchUUID: UUID
    /// Raw wire `kind` string, preserved verbatim so unknown kinds still display.
    public var kindRawValue: String
    public var date: Date
    /// The player's own note on the event (never overwritten by a coach label).
    public var note: String?
    /// The coach's annotation (`coach_label`), stored separately from `note`.
    public var coachLabel: String?
    /// `manual` / `automatic` when known; decoded tolerantly (unknown strings ⇒ nil).
    public var source: MatchEventSource?

    /// The parsed event kind, or nil when this build doesn't recognize `kindRawValue`.
    public var kind: MatchEventKind? { MatchEventKind(rawValue: kindRawValue) }

    public init(id: UUID = UUID(), playerName: String, matchUUID: UUID, kindRawValue: String,
                date: Date, note: String? = nil, coachLabel: String? = nil,
                source: MatchEventSource? = nil) {
        self.id = id
        self.playerName = playerName
        self.matchUUID = matchUUID
        self.kindRawValue = kindRawValue
        self.date = date
        self.note = note
        self.coachLabel = coachLabel
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case playerName = "player_name"
        case matchUUID = "match_uuid"
        case kindRawValue = "kind"
        case date
        case note
        case coachLabel = "coach_label"
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        playerName = try container.decode(String.self, forKey: .playerName)
        matchUUID = try container.decode(UUID.self, forKey: .matchUUID)
        kindRawValue = try container.decode(String.self, forKey: .kindRawValue)
        date = try container.decode(Date.self, forKey: .date)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        coachLabel = try container.decodeIfPresent(String.self, forKey: .coachLabel)
        // Tolerant: an unknown/garbage source string decodes to nil rather than throwing.
        source = (try? container.decodeIfPresent(MatchEventSource.self, forKey: .source)) ?? nil
    }
}

/// Backend-computed team formation (via `GET /teams/{code}/formation`, V2 §3).
public struct TeamFormation: Codable, Sendable {
    public var name: String        // e.g. "4-4-2"
    public var confidence: Double
    public var slots: [Slot]       // player -> normalized mean point

    public init(name: String, confidence: Double, slots: [Slot]) {
        self.name = name
        self.confidence = confidence
        self.slots = slots
    }

    public struct Slot: Codable, Sendable {
        public var playerName: String
        public var x: Double
        public var y: Double
        public var role: String

        public init(playerName: String, x: Double, y: Double, role: String) {
            self.playerName = playerName
            self.x = x
            self.y = y
            self.role = role
        }

        private enum CodingKeys: String, CodingKey {
            case playerName = "player_name"
            case x
            case y
            case role
        }
    }
}

/// Which peer group a benchmark request compares against. Wire value goes in the `cohort` query
/// of `GET /players/me/benchmark` (V2 §12): age band from the player's optional birth year,
/// playing position from `PositionAnalyzer` uploads, or everyone.
public enum BenchmarkCohort: String, CaseIterable, Identifiable, Sendable {
    case ageBand, position, everyone

    public var id: String { rawValue }

    /// The `cohort=` query value the backend expects (`age_band` | `position` | `all`).
    public var wireValue: String {
        switch self {
        case .ageBand: return "age_band"
        case .position: return "position"
        case .everyone: return "all"
        }
    }

    /// Short chip label for the client picker.
    public var label: String {
        switch self {
        case .ageBand: return "Age band"
        case .position: return "Position"
        case .everyone: return "Everyone"
        }
    }
}

/// This player's standing within a peer cohort, from `GET /players/me/benchmark?cohort=…`
/// (V2 §12). Every `percentile` is 0–100 — the player's rank within the cohort for that metric.
///
/// k-anonymity is enforced server-side: the endpoint answers `404 insufficient_data` until a
/// cohort has ≥25 players, so a *decoded* value's `sampleSize` is always at or above that floor,
/// and the response never enumerates cohort members — only aggregates.
///
/// `contributionStreak` / `badgeCount` are optional touchline-walk contribution rewards: absent on
/// backends (or players) without any field-walk history, present as small counters otherwise.
public struct CohortBenchmark: Codable, Sendable {
    /// Human-readable cohort descriptor, e.g. "30–39 · Midfield" or "Everyone".
    public var cohort: String
    /// Number of players in the cohort (≥ the k-anonymity floor whenever this decodes).
    public var sampleSize: Int
    /// Per-metric percentiles (0–100), keyed to match the wire under `percentiles`.
    public var percentiles: Percentiles
    /// Contribution reward: the player's current touchline-walk streak, if any.
    public var contributionStreak: Int?
    /// Contribution reward: badges earned from field-walk contributions, if any.
    public var badgeCount: Int?

    public init(cohort: String, sampleSize: Int, percentiles: Percentiles,
                contributionStreak: Int? = nil, badgeCount: Int? = nil) {
        self.cohort = cohort
        self.sampleSize = sampleSize
        self.percentiles = percentiles
        self.contributionStreak = contributionStreak
        self.badgeCount = badgeCount
    }

    /// The 0–100 percentile rank for each benchmarked metric. Nested under `percentiles` on the
    /// wire, mirroring the `speed_zones` blob shape on `MatchStats`.
    public struct Percentiles: Codable, Sendable {
        public var workrate: Double
        public var distancePerMatchMeters: Double
        public var sprintDistanceMeters: Double
        public var highSpeedRunningMeters: Double
        public var topSpeedMetersPerSecond: Double

        public init(workrate: Double, distancePerMatchMeters: Double, sprintDistanceMeters: Double,
                    highSpeedRunningMeters: Double, topSpeedMetersPerSecond: Double) {
            self.workrate = workrate
            self.distancePerMatchMeters = distancePerMatchMeters
            self.sprintDistanceMeters = sprintDistanceMeters
            self.highSpeedRunningMeters = highSpeedRunningMeters
            self.topSpeedMetersPerSecond = topSpeedMetersPerSecond
        }

        private enum CodingKeys: String, CodingKey {
            case workrate
            case distancePerMatchMeters = "distance_per_match_m"
            case sprintDistanceMeters = "sprint_distance_m"
            case highSpeedRunningMeters = "high_speed_running_m"
            case topSpeedMetersPerSecond = "top_speed_ms"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case cohort
        case sampleSize = "sample_size"
        case percentiles
        case contributionStreak = "contribution_streak"
        case badgeCount = "badge_count"
    }
}

/// Last-known live status for one teammate, from `GET /teams/{code}/live` (V2 §1). `x` / `y` are
/// normalized field coordinates when the relaying phone knows the field, else nil. `stale` is set
/// by the server when `updatedAt` is older than 30 s.
public struct LivePlayerStatus: Codable, Sendable {
    public var playerName: String
    public var updatedAt: Date
    public var x: Double?
    public var y: Double?
    public var heartRate: Double?
    public var distanceMeters: Double
    public var onPitch: Bool
    public var stale: Bool

    public init(playerName: String, updatedAt: Date, x: Double? = nil, y: Double? = nil,
                heartRate: Double? = nil, distanceMeters: Double, onPitch: Bool, stale: Bool) {
        self.playerName = playerName
        self.updatedAt = updatedAt
        self.x = x
        self.y = y
        self.heartRate = heartRate
        self.distanceMeters = distanceMeters
        self.onPitch = onPitch
        self.stale = stale
    }

    private enum CodingKeys: String, CodingKey {
        case playerName = "player_name"
        case updatedAt = "updated_at"
        case x
        case y
        case heartRate = "heart_rate"
        case distanceMeters = "distance_m"
        case onPitch = "on_pitch"
        case stale
    }
}
