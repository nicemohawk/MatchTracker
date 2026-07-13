import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Backend

/// Summary statistics uploaded alongside a match. Encodes the exact `stats` blob shape the
/// backend expects (see docs/BACKEND_UPGRADE_PROMPT.md): snake_case keys, a nested `speed_zones`
/// object, and optional heart-rate / position fields.
public struct MatchStats: Codable, Sendable {
    public var totalDistanceMeters: Double
    public var timeOnPitch: TimeInterval
    public var sprintCount: Int
    public var runCount: Int
    public var workrateScore: Double
    public var speedZones: SpeedZones
    public var averageHeartRate: Double?
    public var positionRole: PositionRole?
    public var positionSide: PositionSide?

    public init(totalDistanceMeters: Double = 0, timeOnPitch: TimeInterval = 0, sprintCount: Int = 0, runCount: Int = 0, workrateScore: Double = 0, speedZones: SpeedZones = SpeedZones(), averageHeartRate: Double? = nil, positionRole: PositionRole? = nil, positionSide: PositionSide? = nil) {
        self.totalDistanceMeters = totalDistanceMeters
        self.timeOnPitch = timeOnPitch
        self.sprintCount = sprintCount
        self.runCount = runCount
        self.workrateScore = workrateScore
        self.speedZones = speedZones
        self.averageHeartRate = averageHeartRate
        self.positionRole = positionRole
        self.positionSide = positionSide
    }

    /// Derive the upload stats from the Kit's analytics outputs. This is the single place the
    /// wire summary is assembled from a `WorkrateReport` (+ optional `PositionEstimate`).
    public init(report: WorkrateReport, position: PositionEstimate? = nil) {
        self.init(
            totalDistanceMeters: report.totalDistanceMeters,
            timeOnPitch: report.timeOnPitch,
            sprintCount: report.sprintCount,
            runCount: report.runCount,
            workrateScore: report.workrateScore,
            speedZones: report.speedZones,
            averageHeartRate: report.averageHeartRate,
            positionRole: position?.role,
            positionSide: position?.side
        )
    }

    private enum CodingKeys: String, CodingKey {
        case totalDistanceMeters = "total_distance_m"
        case timeOnPitch = "time_on_pitch_s"
        case sprintCount = "sprint_count"
        case runCount = "run_count"
        case workrateScore = "workrate_score"
        case speedZones = "speed_zones"
        case averageHeartRate = "avg_hr"
        case positionRole = "position_role"
        case positionSide = "position_side"
    }

    /// Wire shape of `speed_zones`: seconds per zone with `_s`-suffixed keys.
    private enum SpeedZoneKeys: String, CodingKey {
        case standing = "standing_s"
        case walking = "walking_s"
        case jogging = "jogging_s"
        case running = "running_s"
        case sprinting = "sprinting_s"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalDistanceMeters, forKey: .totalDistanceMeters)
        try container.encode(timeOnPitch, forKey: .timeOnPitch)
        try container.encode(sprintCount, forKey: .sprintCount)
        try container.encode(runCount, forKey: .runCount)
        try container.encode(workrateScore, forKey: .workrateScore)
        try container.encodeIfPresent(averageHeartRate, forKey: .averageHeartRate)
        try container.encodeIfPresent(positionRole, forKey: .positionRole)
        try container.encodeIfPresent(positionSide, forKey: .positionSide)

        var zones = container.nestedContainer(keyedBy: SpeedZoneKeys.self, forKey: .speedZones)
        try zones.encode(speedZones.standing, forKey: .standing)
        try zones.encode(speedZones.walking, forKey: .walking)
        try zones.encode(speedZones.jogging, forKey: .jogging)
        try zones.encode(speedZones.running, forKey: .running)
        try zones.encode(speedZones.sprinting, forKey: .sprinting)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalDistanceMeters = try container.decodeIfPresent(Double.self, forKey: .totalDistanceMeters) ?? 0
        timeOnPitch = try container.decodeIfPresent(TimeInterval.self, forKey: .timeOnPitch) ?? 0
        sprintCount = try container.decodeIfPresent(Int.self, forKey: .sprintCount) ?? 0
        runCount = try container.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
        workrateScore = try container.decodeIfPresent(Double.self, forKey: .workrateScore) ?? 0
        averageHeartRate = try container.decodeIfPresent(Double.self, forKey: .averageHeartRate)
        positionRole = try container.decodeIfPresent(PositionRole.self, forKey: .positionRole)
        positionSide = try container.decodeIfPresent(PositionSide.self, forKey: .positionSide)

        if let zones = try? container.nestedContainer(keyedBy: SpeedZoneKeys.self, forKey: .speedZones) {
            speedZones = SpeedZones(
                standing: try zones.decodeIfPresent(TimeInterval.self, forKey: .standing) ?? 0,
                walking: try zones.decodeIfPresent(TimeInterval.self, forKey: .walking) ?? 0,
                jogging: try zones.decodeIfPresent(TimeInterval.self, forKey: .jogging) ?? 0,
                running: try zones.decodeIfPresent(TimeInterval.self, forKey: .running) ?? 0,
                sprinting: try zones.decodeIfPresent(TimeInterval.self, forKey: .sprinting) ?? 0
            )
        } else {
            speedZones = SpeedZones()
        }
    }
}

/// Mirrors the legacy "sessions" wire shape:
/// `{ "track": {"coordinates": [[lat,lon],...]}, "recorded_at": ISO8601, "uuid": "..." }`
/// plus `events`, `field_uuid`, `team_code`, `stats`.
public struct MatchPayload: Codable, Sendable {
    public var uuid: UUID
    public var recordedAt: Date
    public var coordinates: [[Double]]   // [[lat, lon], ...]
    public var events: [MatchEvent]
    public var fieldUUID: UUID?
    public var teamCode: String?
    public var playerName: String?
    public var stats: MatchStats

    public init(uuid: UUID, recordedAt: Date, coordinates: [[Double]], events: [MatchEvent], fieldUUID: UUID?, teamCode: String?, playerName: String? = nil, stats: MatchStats) {
        self.uuid = uuid
        self.recordedAt = recordedAt
        self.coordinates = coordinates
        self.events = events
        self.fieldUUID = fieldUUID
        self.teamCode = teamCode
        self.playerName = playerName
        self.stats = stats
    }

    private enum CodingKeys: String, CodingKey {
        case track
        case recordedAt = "recorded_at"
        case uuid
        case events
        case fieldUUID = "field_uuid"
        case teamCode = "team_code"
        case playerName = "player_name"
        case stats
    }

    private enum TrackKeys: String, CodingKey {
        case coordinates
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var track = container.nestedContainer(keyedBy: TrackKeys.self, forKey: .track)
        try track.encode(coordinates, forKey: .coordinates)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encode(uuid, forKey: .uuid)
        try container.encode(events, forKey: .events)
        try container.encodeIfPresent(fieldUUID, forKey: .fieldUUID)
        try container.encodeIfPresent(teamCode, forKey: .teamCode)
        try container.encodeIfPresent(playerName, forKey: .playerName)
        try container.encode(stats, forKey: .stats)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let track = try container.nestedContainer(keyedBy: TrackKeys.self, forKey: .track)
        coordinates = try track.decode([[Double]].self, forKey: .coordinates)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        uuid = try container.decode(UUID.self, forKey: .uuid)
        events = try container.decodeIfPresent([MatchEvent].self, forKey: .events) ?? []
        fieldUUID = try container.decodeIfPresent(UUID.self, forKey: .fieldUUID)
        teamCode = try container.decodeIfPresent(String.self, forKey: .teamCode)
        playerName = try container.decodeIfPresent(String.self, forKey: .playerName)
        stats = try container.decode(MatchStats.self, forKey: .stats)
    }
}

/// Per-player team aggregates returned by the backend.
public struct TeamStats: Codable, Sendable {
    public struct Player: Codable, Sendable {
        public var name: String
        public var matchesPlayed: Int
        public var totalDistanceMeters: Double
        public var averageWorkrateScore: Double
        public var goals: Int
        public var assists: Int
        public var minutesPlayed: Double?
        public var sprints: Int?

        public init(name: String, matchesPlayed: Int, totalDistanceMeters: Double, averageWorkrateScore: Double, goals: Int, assists: Int, minutesPlayed: Double? = nil, sprints: Int? = nil) {
            self.name = name
            self.matchesPlayed = matchesPlayed
            self.totalDistanceMeters = totalDistanceMeters
            self.averageWorkrateScore = averageWorkrateScore
            self.goals = goals
            self.assists = assists
            self.minutesPlayed = minutesPlayed
            self.sprints = sprints
        }

        private enum CodingKeys: String, CodingKey {
            case name = "player_name"
            case matchesPlayed = "matches_played"
            case totalDistanceMeters = "total_distance_m"
            case averageWorkrateScore = "avg_workrate_score"
            case goals
            case assists
            case minutesPlayed = "total_minutes"
            case sprints = "total_sprints"
        }
    }

    public var teamCode: String
    public var players: [Player]

    public init(teamCode: String, players: [Player]) {
        self.teamCode = teamCode
        self.players = players
    }

    private enum CodingKeys: String, CodingKey {
        case teamCode = "team_code"
        case players
    }
}

public struct APIClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://match-tracks.service.nicemohawk.com")!

    private let baseURL: URL
    private let apiKey: String
    private let deviceID: UUID
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, deviceID: UUID) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.deviceID = deviceID
        self.session = URLSession(configuration: .default)
    }

    public func post(fields: [FieldModel]) async throws {
        guard !fields.isEmpty else { return }
        let wire = fields.map { field -> FieldWire in
            let coordinates = field.outline.map { [$0.latitude, $0.longitude] }
            return FieldWire(track: .init(coordinates: coordinates), recordedAt: field.createdAt, uuid: field.id)
        }
        try await send(path: "/devices/\(deviceID.uuidString)/fields", body: FieldsEnvelope(fields: wire))
    }

    public func post(matches: [MatchPayload]) async throws {
        guard !matches.isEmpty else { return }
        try await send(path: "/devices/\(deviceID.uuidString)/sessions", body: SessionsEnvelope(sessions: matches))
    }

    public func teamStats(code: String) async throws -> TeamStats {
        let url = baseURL.appendingPathComponent("/teams/\(code)/stats")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TeamStats.self, from: data)
    }

    // MARK: - Private wire helpers

    private struct FieldsEnvelope: Encodable { var fields: [FieldWire] }
    private struct SessionsEnvelope: Encodable { var sessions: [MatchPayload] }

    private struct FieldWire: Encodable {
        struct Track: Encodable { var coordinates: [[Double]] }
        var track: Track
        var recordedAt: Date
        var uuid: UUID

        enum CodingKeys: String, CodingKey {
            case track
            case recordedAt = "recorded_at"
            case uuid
        }
    }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("APIKey \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
    }

    private func send<Body: Encodable>(path: String, body: Body) async throws {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)
        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode)
        }
    }
}

public enum APIError: Error, Sendable {
    case httpStatus(Int)
}
