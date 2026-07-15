import Foundation
import CoreGraphics
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
    /// Normalized field-space mean point (0–1 along long/short axes), sent so the backend formation
    /// clustering (V2 §3) can place each player without the raw track.
    public var meanX: Double?
    public var meanY: Double?
    /// Which signals fed `workrateScore` (`"gps+hr"` / `"gps"` / `"hr"`); wire `effort_source`.
    public var effortSource: String?
    /// Positions the wearer hand-reported for this match (wire `reported_positions`), omitted when
    /// nil. Ground truth the player supplied, distinct from the inferred `position_role`/`side`.
    public var reportedPositions: [ReportedPosition]?

    public init(totalDistanceMeters: Double = 0, timeOnPitch: TimeInterval = 0, sprintCount: Int = 0, runCount: Int = 0, workrateScore: Double = 0, speedZones: SpeedZones = SpeedZones(), averageHeartRate: Double? = nil, positionRole: PositionRole? = nil, positionSide: PositionSide? = nil, meanX: Double? = nil, meanY: Double? = nil, effortSource: String? = nil, reportedPositions: [ReportedPosition]? = nil) {
        self.totalDistanceMeters = totalDistanceMeters
        self.timeOnPitch = timeOnPitch
        self.sprintCount = sprintCount
        self.runCount = runCount
        self.workrateScore = workrateScore
        self.speedZones = speedZones
        self.averageHeartRate = averageHeartRate
        self.positionRole = positionRole
        self.positionSide = positionSide
        self.meanX = meanX
        self.meanY = meanY
        self.effortSource = effortSource
        self.reportedPositions = reportedPositions
    }

    /// Derive the upload stats from the Kit's analytics outputs. This is the single place the
    /// wire summary is assembled from a `WorkrateReport` (+ optional `PositionEstimate`). The
    /// wearer's hand-`reportedPositions` (from the `MatchRecord`, not analytics) pass through here.
    public init(report: WorkrateReport, position: PositionEstimate? = nil, reportedPositions: [ReportedPosition]? = nil) {
        self.init(
            totalDistanceMeters: report.totalDistanceMeters,
            timeOnPitch: report.timeOnPitch,
            sprintCount: report.sprintCount,
            runCount: report.runCount,
            workrateScore: report.workrateScore,
            speedZones: report.speedZones,
            averageHeartRate: report.averageHeartRate,
            positionRole: position?.role,
            positionSide: position?.side,
            meanX: position.map { Double($0.meanPoint.x) },
            meanY: position.map { Double($0.meanPoint.y) },
            effortSource: report.effortSource,
            reportedPositions: reportedPositions
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
        case meanX = "mean_x"
        case meanY = "mean_y"
        case effortSource = "effort_source"
        case reportedPositions = "reported_positions"
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
        try container.encodeIfPresent(meanX, forKey: .meanX)
        try container.encodeIfPresent(meanY, forKey: .meanY)
        try container.encodeIfPresent(effortSource, forKey: .effortSource)
        try container.encodeIfPresent(reportedPositions, forKey: .reportedPositions)

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
        meanX = try container.decodeIfPresent(Double.self, forKey: .meanX)
        meanY = try container.decodeIfPresent(Double.self, forKey: .meanY)
        effortSource = try container.decodeIfPresent(String.self, forKey: .effortSource)
        reportedPositions = try container.decodeIfPresent([ReportedPosition].self, forKey: .reportedPositions)

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
    /// Sport this match was played as (wire `sport_id`); nil ≡ soccer, matching the backend default.
    public var sportID: String?
    /// Match format wire value (`match` / `small_sided` / `indoor`, wire `format`); nil ≡ match.
    /// Set from `MatchFormat.wireValue` so `smallSided` serializes as `small_sided`.
    public var format: String?
    public var stats: MatchStats

    public init(uuid: UUID, recordedAt: Date, coordinates: [[Double]], events: [MatchEvent], fieldUUID: UUID?, teamCode: String?, playerName: String? = nil, sportID: String? = nil, format: String? = nil, stats: MatchStats) {
        self.uuid = uuid
        self.recordedAt = recordedAt
        self.coordinates = coordinates
        self.events = events
        self.fieldUUID = fieldUUID
        self.teamCode = teamCode
        self.playerName = playerName
        self.sportID = sportID
        self.format = format
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
        case sportID = "sport_id"
        case format
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
        try container.encodeIfPresent(sportID, forKey: .sportID)
        try container.encodeIfPresent(format, forKey: .format)
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
        sportID = try container.decodeIfPresent(String.self, forKey: .sportID)
        format = try container.decodeIfPresent(String.self, forKey: .format)
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
        self.init(baseURL: baseURL, apiKey: apiKey, deviceID: deviceID, session: URLSession(configuration: .default))
    }

    /// Testability seam: inject a `URLSession` (e.g. one backed by a `URLProtocol` stub). Not part
    /// of the public API surface.
    init(baseURL: URL, apiKey: String, deviceID: UUID, session: URLSession) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.deviceID = deviceID
        self.session = session
    }

    public func post(fields: [FieldModel]) async throws {
        guard !fields.isEmpty else { return }
        let wire = fields.map { field -> FieldWire in
            let coordinates = field.outline.map { [$0.latitude, $0.longitude] }
            return FieldWire(track: .init(coordinates: coordinates), recordedAt: field.createdAt,
                             uuid: field.id, sportID: field.sportID)
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

    // MARK: - V2 team & live endpoints

    /// Team chat for a match (`GET /matches/{uuid}/comments`), oldest-first.
    public func comments(match: UUID) async throws -> [MatchComment] {
        let data = try await get(path: "/matches/\(match.uuidString)/comments")
        return try Self.jsonDecoder().decode(CommentsEnvelope.self, from: data).comments
    }

    /// Post a comment (`POST /matches/{uuid}/comments`). Idempotent by `comment.id`; the server
    /// stamps `posted_at` and resolves the author from the device, using the sent `author` only as a
    /// fallback.
    public func postComment(_ comment: MatchComment, match: UUID) async throws {
        let body = CommentPost(id: comment.id, body: comment.body, author: comment.author)
        try await postJSON(path: "/matches/\(match.uuidString)/comments", body: body)
    }

    /// Backend-computed formation over the team's recent matches
    /// (`GET /teams/{code}/formation?window_days=`).
    public func formation(code: String, windowDays: Int = 30) async throws -> TeamFormation {
        let data = try await get(path: "/teams/\(code)/formation?window_days=\(windowDays)")
        return try Self.jsonDecoder().decode(TeamFormation.self, from: data)
    }

    /// This player's peer-cohort standing (`GET /players/me/benchmark?cohort=…`, V2 §12).
    /// `cohort` selects the comparison group (age band / position / everyone). Idempotent GET.
    /// The backend enforces k-anonymity, answering `404` (`insufficient_data`) until the cohort
    /// reaches ≥25 players — callers surface that as a quiet "unlocks as the community grows"
    /// state, never an error. Any non-2xx throws `APIError.httpStatus`.
    public func benchmark(cohort: BenchmarkCohort) async throws -> CohortBenchmark {
        let data = try await get(path: "/players/me/benchmark?cohort=\(cohort.wireValue)")
        return try Self.jsonDecoder().decode(CohortBenchmark.self, from: data)
    }

    /// Last-known live status for every teammate (`GET /teams/{code}/live`).
    public func liveTeam(code: String) async throws -> [LivePlayerStatus] {
        let data = try await get(path: "/teams/\(code)/live")
        return try Self.jsonDecoder().decode(LiveEnvelope.self, from: data).players
    }

    /// Unified team event timeline (`GET /teams/{code}/events?since_hours=`, V2 §11): every
    /// teammate's tagged events from recent matches, coalesced and ordered oldest-first.
    public func teamEvents(code: String, sinceHours: Int = 6) async throws -> [TeamEvent] {
        let data = try await get(path: "/teams/\(code)/events?since_hours=\(sinceHours)")
        return try Self.jsonDecoder().decode(TeamEventsEnvelope.self, from: data).events
    }

    /// Attach (or overwrite) a coach label on one team event
    /// (`POST /matches/{match_uuid}/events/{id}/annotation`, V2 §11). Idempotent: re-posting a
    /// different label replaces `coach_label`; the player's own note is never touched.
    public func annotateEvent(id: UUID, matchUUID: UUID, label: String) async throws {
        try await postJSON(path: "/matches/\(matchUUID.uuidString)/events/\(id.uuidString)/annotation",
                           body: AnnotationPost(label: label))
    }

    /// Relay one live update to the backend (`POST /devices/{id}/live`, V2 §1). The watch->phone-only
    /// `latestPoints` (raw track) are stripped, but `newEvents` are forwarded as `new_events` so live
    /// events reach the team-scoped event log (V2 §11); `matchUUID` and `teamCode` are added.
    public func postLive(_ update: LiveMatchUpdate, matchUUID: UUID, teamCode: String) async throws {
        try await postJSON(path: "/devices/\(deviceID.uuidString)/live",
                           body: LiveWire(update: update, matchUUID: matchUUID, teamCode: teamCode))
    }

    /// Record guardian consent for a minor (`POST /devices/{id}/consent`, V2 §5).
    public func postConsent(guardianName: String) async throws {
        try await postJSON(path: "/devices/\(deviceID.uuidString)/consent",
                           body: ConsentPost(guardianName: guardianName, acknowledged: true))
    }

    /// Request full server-side deletion of this device's data (`DELETE /devices/{id}`, V2 §5).
    public func requestDeletion() async throws {
        var request = URLRequest(url: makeURL("/devices/\(deviceID.uuidString)"))
        request.httpMethod = "DELETE"
        applyHeaders(to: &request)
        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
    }

    // MARK: - Private wire helpers

    private struct ConsentPost: Encodable {
        var guardianName: String
        var acknowledged: Bool
        enum CodingKeys: String, CodingKey {
            case guardianName = "guardian_name"
            case acknowledged
        }
    }


    private struct FieldsEnvelope: Encodable { var fields: [FieldWire] }
    private struct SessionsEnvelope: Encodable { var sessions: [MatchPayload] }
    private struct CommentsEnvelope: Decodable { var comments: [MatchComment] }
    private struct LiveEnvelope: Decodable { var players: [LivePlayerStatus] }
    private struct TeamEventsEnvelope: Decodable { var events: [TeamEvent] }

    /// Coach annotation body: just the label. The server keys the event by the path uuids.
    private struct AnnotationPost: Encodable { var label: String }

    /// Minimal comment POST body: the backend derives `posted_at` and (usually) the author.
    private struct CommentPost: Encodable { var id: UUID; var body: String; var author: String }

    /// `LiveMatchUpdate` reduced to the backend contract: the raw track delta (`latestPoints`) is
    /// dropped, but `newEvents` are forwarded as `new_events` so the server can append them to the
    /// team-scoped live event log (V2 §1/§11). Routing keys `matchUUID` / `teamCode` are added.
    private struct LiveWire: Encodable {
        var matchUUID: UUID
        var teamCode: String
        var sequence: Int
        var timestamp: Date
        var elapsedSeconds: TimeInterval
        var heartRate: Double?
        var distanceMeters: Double
        var currentSpeed: Double?
        var onPitch: Bool
        var usGoals: Int?
        var themGoals: Int?
        /// Events logged since the last update, forwarded verbatim via `MatchEvent`'s own Codable.
        var newEvents: [MatchEvent]

        init(update: LiveMatchUpdate, matchUUID: UUID, teamCode: String) {
            self.matchUUID = matchUUID
            self.teamCode = teamCode
            self.sequence = update.sequence
            self.timestamp = update.timestamp
            self.elapsedSeconds = update.elapsed
            self.heartRate = update.heartRate
            self.distanceMeters = update.distanceMeters
            self.currentSpeed = update.currentSpeed
            self.onPitch = update.onPitch
            self.usGoals = update.usGoals
            self.themGoals = update.themGoals
            self.newEvents = update.newEvents
        }

        enum CodingKeys: String, CodingKey {
            case matchUUID = "match_uuid"
            case teamCode = "team_code"
            case sequence
            case timestamp
            case elapsedSeconds = "elapsed_s"
            case heartRate = "heart_rate"
            case distanceMeters = "distance_m"
            case currentSpeed = "current_speed"
            case onPitch = "on_pitch"
            case usGoals = "us_goals"
            case themGoals = "them_goals"
            case newEvents = "new_events"
        }
    }

    private struct FieldWire: Encodable {
        struct Track: Encodable { var coordinates: [[Double]] }
        var track: Track
        var recordedAt: Date
        var uuid: UUID
        var sportID: String?

        enum CodingKeys: String, CodingKey {
            case track
            case recordedAt = "recorded_at"
            case uuid
            case sportID = "sport_id"
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

    /// Builds a request URL, preserving any query string in `path` (which `appendingPathComponent`
    /// would percent-escape).
    private func makeURL(_ path: String) -> URL {
        URL(string: baseURL.absoluteString + path) ?? baseURL.appendingPathComponent(path)
    }

    private func get(path: String) async throws -> Data {
        var request = URLRequest(url: makeURL(path))
        request.httpMethod = "GET"
        applyHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return data
    }

    private func postJSON<Body: Encodable>(path: String, body: Body) async throws {
        var request = URLRequest(url: makeURL(path))
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.httpBody = try Self.jsonEncoder().encode(body)
        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
    }

    private static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
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
