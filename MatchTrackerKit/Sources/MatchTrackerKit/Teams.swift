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
