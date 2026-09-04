import Foundation

// MARK: - Live streaming (watch -> phone during a match)

/// One delta of live match state streamed from the watch to the phone (via
/// `WCSession.sendMessage` with `transferUserInfo` fallback, key `"liveUpdate"`), roughly every
/// five seconds while the phone is reachable.
///
/// The wire keys match the backend `POST /devices/{id}/live` contract (see
/// `docs/BACKEND_UPGRADE_PROMPT_V2.md` §1): `elapsed_s`, `heart_rate`, `distance_m`,
/// `current_speed`, `on_pitch`, `us_goals`, `them_goals`. `latestPoints` / `newEvents` exist ONLY
/// for the watch -> phone link (so the phone can extend its track and event list live); the phone
/// strips them before relaying to the backend (see `APIClient.postLive`).
public struct LiveMatchUpdate: Codable, Sendable {
    public var sequence: Int
    public var timestamp: Date
    public var elapsed: TimeInterval
    public var heartRate: Double?
    public var distanceMeters: Double
    public var currentSpeed: Double?
    public var onPitch: Bool
    /// Small delta batch of new track points since the last update (watch -> phone only, <= ~10).
    public var latestPoints: [TrackPoint]
    /// Events logged since the last update (watch -> phone only).
    public var newEvents: [MatchEvent]
    /// Current scoreline, stored as two optional Ints (`us_goals` / `them_goals`); both nil until
    /// the wearer records a goal.
    public var usGoals: Int?
    public var themGoals: Int?

    public init(sequence: Int, timestamp: Date, elapsed: TimeInterval, heartRate: Double? = nil,
                distanceMeters: Double, currentSpeed: Double? = nil, onPitch: Bool,
                latestPoints: [TrackPoint] = [], newEvents: [MatchEvent] = [],
                usGoals: Int? = nil, themGoals: Int? = nil) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.elapsed = elapsed
        self.heartRate = heartRate
        self.distanceMeters = distanceMeters
        self.currentSpeed = currentSpeed
        self.onPitch = onPitch
        self.latestPoints = latestPoints
        self.newEvents = newEvents
        self.usGoals = usGoals
        self.themGoals = themGoals
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case timestamp
        case elapsed = "elapsed_s"
        case heartRate = "heart_rate"
        case distanceMeters = "distance_m"
        case currentSpeed = "current_speed"
        case onPitch = "on_pitch"
        case latestPoints = "latest_points"
        case newEvents = "new_events"
        case usGoals = "us_goals"
        case themGoals = "them_goals"
    }
}
