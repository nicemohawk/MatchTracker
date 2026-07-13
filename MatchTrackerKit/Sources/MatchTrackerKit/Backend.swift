import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Backend

/// Summary statistics uploaded alongside a match (subset of `WorkrateReport`).
public struct MatchStats: Codable, Sendable {
    public var totalDistanceMeters: Double
    public var timeOnPitch: TimeInterval
    public var sprintCount: Int
    public var runCount: Int
    public var workrateScore: Double
    public var averageHeartRate: Double?

    public init(totalDistanceMeters: Double = 0, timeOnPitch: TimeInterval = 0, sprintCount: Int = 0, runCount: Int = 0, workrateScore: Double = 0, averageHeartRate: Double? = nil) {
        self.totalDistanceMeters = totalDistanceMeters
        self.timeOnPitch = timeOnPitch
        self.sprintCount = sprintCount
        self.runCount = runCount
        self.workrateScore = workrateScore
        self.averageHeartRate = averageHeartRate
    }

    public init(report: WorkrateReport) {
        self.init(
            totalDistanceMeters: report.totalDistanceMeters,
            timeOnPitch: report.timeOnPitch,
            sprintCount: report.sprintCount,
            runCount: report.runCount,
            workrateScore: report.workrateScore,
            averageHeartRate: report.averageHeartRate
        )
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
    public var stats: MatchStats

    public init(uuid: UUID, recordedAt: Date, coordinates: [[Double]], events: [MatchEvent], fieldUUID: UUID?, teamCode: String?, stats: MatchStats) {
        self.uuid = uuid
        self.recordedAt = recordedAt
        self.coordinates = coordinates
        self.events = events
        self.fieldUUID = fieldUUID
        self.teamCode = teamCode
        self.stats = stats
    }

    private enum CodingKeys: String, CodingKey {
        case track
        case recordedAt = "recorded_at"
        case uuid
        case events
        case fieldUUID = "field_uuid"
        case teamCode = "team_code"
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

        public init(name: String, matchesPlayed: Int, totalDistanceMeters: Double, averageWorkrateScore: Double, goals: Int, assists: Int) {
            self.name = name
            self.matchesPlayed = matchesPlayed
            self.totalDistanceMeters = totalDistanceMeters
            self.averageWorkrateScore = averageWorkrateScore
            self.goals = goals
            self.assists = assists
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
