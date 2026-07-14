import XCTest
import CoreGraphics
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MatchTrackerKit

// MARK: - Test support

/// Reads a request body whether URLSession left it on `httpBody` or moved it to `httpBodyStream`
/// (which it does for `URLProtocol` interception).
private extension URLRequest {
    var capturedBody: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Records every intercepted request and replies with a canned response.
final class StubURLProtocol: URLProtocol {
    struct Stub { var statusCode: Int; var body: Data }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(request: URLRequest, body: Data?)] = []
        func record(_ request: URLRequest) {
            lock.lock(); storage.append((request, request.capturedBody)); lock.unlock()
        }
        var requests: [(request: URLRequest, body: Data?)] {
            lock.lock(); defer { lock.unlock() }; return storage
        }
    }

    nonisolated(unsafe) static var stub = Stub(statusCode: 204, body: Data())
    nonisolated(unsafe) static var recorder = Recorder()

    static func reset(statusCode: Int = 204, body: Data = Data()) {
        stub = Stub(statusCode: statusCode, body: body)
        recorder = Recorder()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.recorder.record(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.stub.statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class RoadmapBackendTests: XCTestCase {

    private let baseURL = URL(string: "https://example.test")!
    private let deviceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000DE")!

    private func stubbedClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return APIClient(baseURL: baseURL, apiKey: "SECRET", deviceID: deviceID, session: session)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let isoEncoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder
    }()
    private static let isoDecoder: JSONDecoder = {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }()

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - LiveMatchUpdate

    func testLiveMatchUpdateWireKeysAndRoundTrip() throws {
        let point = TrackPoint(coordinate: Coordinate2D(latitude: 40, longitude: -83),
                               timestamp: Date(timeIntervalSince1970: 100),
                               speedMetersPerSecond: 2.0, courseDegrees: 90, horizontalAccuracy: 5)
        let event = MatchEvent(id: UUID(), kind: .flag, date: Date(timeIntervalSince1970: 90), note: "x")
        let update = LiveMatchUpdate(sequence: 42, timestamp: Date(timeIntervalSince1970: 200),
                                     elapsed: 1810.5, heartRate: 156, distanceMeters: 4321,
                                     currentSpeed: 3.2, onPitch: true,
                                     latestPoints: [point], newEvents: [event],
                                     usGoals: 1, themGoals: 0)

        let data = try Self.isoEncoder.encode(update)
        let json = try jsonObject(data)
        for key in ["sequence", "timestamp", "elapsed_s", "heart_rate", "distance_m",
                    "current_speed", "on_pitch", "us_goals", "them_goals",
                    "latest_points", "new_events"] {
            XCTAssertNotNil(json[key], "missing wire key \(key)")
        }
        XCTAssertEqual(json["elapsed_s"] as? Double, 1810.5)
        XCTAssertEqual(json["us_goals"] as? Int, 1)

        let decoded = try Self.isoDecoder.decode(LiveMatchUpdate.self, from: data)
        XCTAssertEqual(decoded.sequence, 42)
        XCTAssertEqual(decoded.elapsed, 1810.5)
        XCTAssertEqual(decoded.heartRate, 156)
        XCTAssertEqual(decoded.distanceMeters, 4321)
        XCTAssertEqual(decoded.currentSpeed, 3.2)
        XCTAssertEqual(decoded.onPitch, true)
        XCTAssertEqual(decoded.usGoals, 1)
        XCTAssertEqual(decoded.themGoals, 0)
        XCTAssertEqual(decoded.latestPoints, [point])
        XCTAssertEqual(decoded.newEvents, [event])
    }

    func testLiveMatchUpdateOmitsNilScore() throws {
        let update = LiveMatchUpdate(sequence: 1, timestamp: Date(timeIntervalSince1970: 0),
                                     elapsed: 0, distanceMeters: 0, onPitch: false)
        let json = try jsonObject(try Self.isoEncoder.encode(update))
        XCTAssertNil(json["us_goals"])
        XCTAssertNil(json["them_goals"])
        XCTAssertNil(json["heart_rate"])
    }

    // MARK: - Teams wire keys

    func testTeamMembershipWireKeys() throws {
        let membership = TeamMembership(code: "ABC123", name: "U12", displayInitialsOnly: true)
        let json = try jsonObject(try Self.isoEncoder.encode(membership))
        XCTAssertEqual(json["code"] as? String, "ABC123")
        XCTAssertEqual(json["initials_only"] as? Bool, true)
        XCTAssertNil(json["displayInitialsOnly"])
    }

    func testMatchCommentWireKeys() throws {
        let comment = MatchComment(id: UUID(), matchUUID: UUID(), author: "Ben L",
                                   body: "great pressing", postedAt: Date(timeIntervalSince1970: 0))
        let json = try jsonObject(try Self.isoEncoder.encode(comment))
        XCTAssertNotNil(json["match_uuid"])
        XCTAssertNotNil(json["posted_at"])
        XCTAssertEqual(json["author"] as? String, "Ben L")
        XCTAssertNil(json["matchUUID"])
        XCTAssertNil(json["postedAt"])
    }

    func testTeamFormationSlotWireKeys() throws {
        let formation = TeamFormation(name: "4-3-3", confidence: 0.74,
                                      slots: [.init(playerName: "Ben L", x: 0.35, y: 0.18, role: "left midfielder")])
        let json = try jsonObject(try Self.isoEncoder.encode(formation))
        let slots = try XCTUnwrap(json["slots"] as? [[String: Any]])
        XCTAssertEqual(slots.first?["player_name"] as? String, "Ben L")
        XCTAssertNil(slots.first?["playerName"])
    }

    func testLivePlayerStatusWireKeys() throws {
        let status = LivePlayerStatus(playerName: "Ben L", updatedAt: Date(timeIntervalSince1970: 0),
                                      x: 0.62, y: 0.31, heartRate: 156, distanceMeters: 4321,
                                      onPitch: true, stale: false)
        let json = try jsonObject(try Self.isoEncoder.encode(status))
        for key in ["player_name", "updated_at", "heart_rate", "distance_m", "on_pitch", "stale"] {
            XCTAssertNotNil(json[key], "missing wire key \(key)")
        }

        // Decode the documented GET /teams/{code}/live shape.
        let wire = """
        {"player_name":"Sam K","updated_at":"1970-01-01T00:00:00Z","x":0.5,"y":0.5,
         "heart_rate":140.0,"distance_m":1200.0,"on_pitch":false,"stale":true}
        """.data(using: .utf8)!
        let decoded = try Self.isoDecoder.decode(LivePlayerStatus.self, from: wire)
        XCTAssertEqual(decoded.playerName, "Sam K")
        XCTAssertEqual(decoded.onPitch, false)
        XCTAssertEqual(decoded.stale, true)
    }

    // MARK: - MatchPayload / MatchStats wire keys

    func testMatchStatsMeanKeysFromPosition() throws {
        let report = WorkrateReport(totalDistanceMeters: 1000, timeOnPitch: 600, workrateScore: 50)
        let position = PositionEstimate(role: .midfielder, side: .center, confidence: 0.8,
                                        meanPoint: CGPoint(x: 0.62, y: 0.31), periodMeanPoints: [])
        let stats = MatchStats(report: report, position: position)
        XCTAssertEqual(try XCTUnwrap(stats.meanX), 0.62, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(stats.meanY), 0.31, accuracy: 1e-6)

        let json = try jsonObject(try Self.isoEncoder.encode(stats))
        XCTAssertEqual(json["mean_x"] as? Double, 0.62)
        XCTAssertEqual(json["mean_y"] as? Double, 0.31)
    }

    func testMatchPayloadSportIDWireKey() throws {
        let payload = MatchPayload(uuid: UUID(), recordedAt: Date(timeIntervalSince1970: 0),
                                   coordinates: [[40, -83]], events: [], fieldUUID: nil,
                                   teamCode: nil, sportID: "rugby", stats: MatchStats())
        let json = try jsonObject(try Self.isoEncoder.encode(payload))
        XCTAssertEqual(json["sport_id"] as? String, "rugby")

        let decoded = try Self.isoDecoder.decode(MatchPayload.self, from: try Self.isoEncoder.encode(payload))
        XCTAssertEqual(decoded.sportID, "rugby")
    }

    // MARK: - Exporters (golden strings)

    private static let goldenA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private static let goldenB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

    private func goldenTrack() -> [TrackPoint] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            TrackPoint(coordinate: Coordinate2D(latitude: 40.0, longitude: -83.0),
                       timestamp: start, speedMetersPerSecond: 1.5, courseDegrees: 90, horizontalAccuracy: 5),
            TrackPoint(coordinate: Coordinate2D(latitude: 40.001, longitude: -83.001),
                       timestamp: start.addingTimeInterval(10), speedMetersPerSecond: 3.25,
                       courseDegrees: -1, horizontalAccuracy: 8)
        ]
    }

    private func goldenEvents() -> [MatchEvent] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            MatchEvent(id: Self.goldenA, kind: .flag, date: start.addingTimeInterval(5),
                       note: "great tackle", source: .manual),
            MatchEvent(id: Self.goldenB, kind: .goalForUs, date: start.addingTimeInterval(8),
                       note: nil, source: .automatic)
        ]
    }

    func testCSVGolden() {
        let expected = """
        timestamp,latitude,longitude,speed_mps,course_deg,horizontal_accuracy_m
        2023-11-14T22:13:20Z,40.000000,-83.000000,1.50,90.00,5.00
        2023-11-14T22:13:30Z,40.001000,-83.001000,3.25,-1.00,8.00

        """
        XCTAssertEqual(MatchExporter.csv(track: goldenTrack()), expected)
    }

    func testEventsCSVGolden() {
        let expected = """
        id,kind,date,note,source
        AAAAAAAA-0000-0000-0000-000000000001,flag,2023-11-14T22:13:25Z,great tackle,manual
        BBBBBBBB-0000-0000-0000-000000000002,goalFor,2023-11-14T22:13:28Z,,automatic

        """
        XCTAssertEqual(MatchExporter.eventsCSV(events: goldenEvents()), expected)
    }

    func testEventsCSVEscapesCommas() {
        let event = MatchEvent(id: Self.goldenA, kind: .flag,
                               date: Date(timeIntervalSince1970: 1_700_000_000),
                               note: "hit, then \"scored\"", source: .manual)
        let csv = MatchExporter.eventsCSV(events: [event])
        XCTAssertTrue(csv.contains("\"hit, then \"\"scored\"\"\""), csv)
    }

    func testGPXGolden() {
        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="MatchTracker" xmlns="http://www.topografix.com/GPX/1/1">
        <metadata><time>2023-11-14T22:13:20Z</time></metadata>
        <wpt lat="40.000000" lon="-83.000000">
        <time>2023-11-14T22:13:25Z</time>
        <name>flag</name>
        <desc>great tackle</desc>
        </wpt>
        <wpt lat="40.001000" lon="-83.001000">
        <time>2023-11-14T22:13:28Z</time>
        <name>goalFor</name>
        </wpt>
        <trk>
        <trkseg>
        <trkpt lat="40.000000" lon="-83.000000">
        <time>2023-11-14T22:13:20Z</time>
        </trkpt>
        <trkpt lat="40.001000" lon="-83.001000">
        <time>2023-11-14T22:13:30Z</time>
        </trkpt>
        </trkseg>
        </trk>
        </gpx>

        """
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(MatchExporter.gpx(track: goldenTrack(), events: goldenEvents(), startDate: start), expected)
    }

    // MARK: - APIClient V2 endpoints

    func testAuthorizationHeader() async throws {
        StubURLProtocol.reset(statusCode: 200,
                              body: #"{"players":[]}"#.data(using: .utf8)!)
        _ = try await stubbedClient().liveTeam(code: "ABC123")
        let request = try XCTUnwrap(StubURLProtocol.recorder.requests.first?.request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "APIKey SECRET")
    }

    func testCommentsUnwrapAndPath() async throws {
        let matchID = UUID()
        let body = """
        {"comments":[{"id":"\(Self.goldenA.uuidString)","match_uuid":"\(matchID.uuidString)",
         "author":"Ben L","body":"nice","posted_at":"2023-11-14T22:13:20Z"}]}
        """.data(using: .utf8)!
        StubURLProtocol.reset(statusCode: 200, body: body)

        let comments = try await stubbedClient().comments(match: matchID)
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.author, "Ben L")
        let request = try XCTUnwrap(StubURLProtocol.recorder.requests.first?.request)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/matches/\(matchID.uuidString)/comments")
    }

    func testPostCommentSendsMinimalBody() async throws {
        let matchID = UUID()
        StubURLProtocol.reset(statusCode: 204)
        let comment = MatchComment(id: Self.goldenA, matchUUID: matchID, author: "Ben L",
                                   body: "great pressing", postedAt: Date(timeIntervalSince1970: 0))
        try await stubbedClient().postComment(comment, match: matchID)

        let recorded = try XCTUnwrap(StubURLProtocol.recorder.requests.first)
        XCTAssertEqual(recorded.request.httpMethod, "POST")
        XCTAssertEqual(recorded.request.url?.path, "/matches/\(matchID.uuidString)/comments")
        let json = try jsonObject(try XCTUnwrap(recorded.body))
        XCTAssertEqual(json["id"] as? String, Self.goldenA.uuidString)
        XCTAssertEqual(json["body"] as? String, "great pressing")
        XCTAssertEqual(json["author"] as? String, "Ben L")
        XCTAssertNil(json["match_uuid"])
        XCTAssertNil(json["posted_at"])
    }

    func testFormationDecodeAndQuery() async throws {
        let body = """
        {"name":"4-3-3","confidence":0.74,
         "slots":[{"player_name":"Ben L","x":0.35,"y":0.18,"role":"left midfielder"}]}
        """.data(using: .utf8)!
        StubURLProtocol.reset(statusCode: 200, body: body)

        let formation = try await stubbedClient().formation(code: "ABC123")
        XCTAssertEqual(formation.name, "4-3-3")
        XCTAssertEqual(formation.slots.first?.playerName, "Ben L")
        let request = try XCTUnwrap(StubURLProtocol.recorder.requests.first?.request)
        XCTAssertEqual(request.url?.query, "window_days=30")
        XCTAssertEqual(request.url?.path, "/teams/ABC123/formation")
    }

    func testPostLiveStripsTrackButForwardsEvents() async throws {
        StubURLProtocol.reset(statusCode: 204)
        let matchID = UUID()
        let eventID = Self.goldenA
        let point = TrackPoint(coordinate: Coordinate2D(latitude: 40, longitude: -83),
                               timestamp: Date(timeIntervalSince1970: 0), speedMetersPerSecond: 1,
                               courseDegrees: 0, horizontalAccuracy: 5)
        let update = LiveMatchUpdate(sequence: 7, timestamp: Date(timeIntervalSince1970: 0),
                                     elapsed: 60, heartRate: 150, distanceMeters: 500,
                                     currentSpeed: 2, onPitch: true,
                                     latestPoints: [point],
                                     newEvents: [MatchEvent(id: eventID, kind: .goalMine,
                                                            date: Date(timeIntervalSince1970: 30),
                                                            note: "header")],
                                     usGoals: 2, themGoals: 1)
        try await stubbedClient().postLive(update, matchUUID: matchID, teamCode: "ABC123")

        let recorded = try XCTUnwrap(StubURLProtocol.recorder.requests.first)
        XCTAssertEqual(recorded.request.url?.path, "/devices/\(deviceID.uuidString)/live")
        let json = try jsonObject(try XCTUnwrap(recorded.body))
        XCTAssertEqual(json["match_uuid"] as? String, matchID.uuidString)
        XCTAssertEqual(json["team_code"] as? String, "ABC123")
        XCTAssertEqual(json["sequence"] as? Int, 7)
        XCTAssertEqual(json["elapsed_s"] as? Double, 60)
        XCTAssertEqual(json["us_goals"] as? Int, 2)
        // Raw track is still stripped; tagged events now reach the server as new_events.
        XCTAssertNil(json["latest_points"])
        let events = try XCTUnwrap(json["new_events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["id"] as? String, eventID.uuidString)
        XCTAssertEqual(events.first?["kind"] as? String, "goalMine")
        XCTAssertEqual(events.first?["note"] as? String, "header")
    }

    func testPostLiveEncodesEmptyEventsAsEmptyArray() async throws {
        StubURLProtocol.reset(statusCode: 204)
        let update = LiveMatchUpdate(sequence: 1, timestamp: Date(timeIntervalSince1970: 0),
                                     elapsed: 0, distanceMeters: 0, onPitch: false)
        try await stubbedClient().postLive(update, matchUUID: UUID(), teamCode: "ABC123")
        let recorded = try XCTUnwrap(StubURLProtocol.recorder.requests.first)
        let json = try jsonObject(try XCTUnwrap(recorded.body))
        let events = try XCTUnwrap(json["new_events"] as? [Any])
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - TeamEvent (team timeline, V2 §11)

    func testTeamEventDecodesWireIncludingCoachLabel() throws {
        let matchID = UUID()
        let eventID = Self.goldenA
        let wire = """
        {"id":"\(eventID.uuidString)","player_name":"Ben L","match_uuid":"\(matchID.uuidString)",
         "kind":"goalMine","date":"2023-11-14T22:13:20Z","note":"top corner",
         "coach_label":"great finish","source":"manual"}
        """.data(using: .utf8)!
        let event = try Self.isoDecoder.decode(TeamEvent.self, from: wire)
        XCTAssertEqual(event.id, eventID)
        XCTAssertEqual(event.playerName, "Ben L")
        XCTAssertEqual(event.matchUUID, matchID)
        XCTAssertEqual(event.kindRawValue, "goalMine")
        XCTAssertEqual(event.kind, .goalMine)
        XCTAssertEqual(event.note, "top corner")
        XCTAssertEqual(event.coachLabel, "great finish")
        XCTAssertEqual(event.source, .manual)
    }

    func testTeamEventToleratesUnknownKindAndSourceAndMissingLabel() throws {
        let wire = """
        {"id":"\(Self.goldenB.uuidString)","player_name":"Sam K","match_uuid":"\(UUID().uuidString)",
         "kind":"cornerKick","date":"2023-11-14T22:13:20Z","source":"referee"}
        """.data(using: .utf8)!
        let event = try Self.isoDecoder.decode(TeamEvent.self, from: wire)
        // Unknown kind is preserved raw; the parsed kind is nil rather than a throw.
        XCTAssertEqual(event.kindRawValue, "cornerKick")
        XCTAssertNil(event.kind)
        // Unknown source string decodes tolerantly to nil.
        XCTAssertNil(event.source)
        XCTAssertNil(event.note)
        XCTAssertNil(event.coachLabel)
    }

    func testTeamEventsUnwrapAndQuery() async throws {
        let body = """
        {"events":[{"id":"\(Self.goldenA.uuidString)","player_name":"Ben L",
         "match_uuid":"\(UUID().uuidString)","kind":"flag","date":"2023-11-14T22:13:20Z"}]}
        """.data(using: .utf8)!
        StubURLProtocol.reset(statusCode: 200, body: body)

        let events = try await stubbedClient().teamEvents(code: "ABC123", sinceHours: 12)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.playerName, "Ben L")
        let request = try XCTUnwrap(StubURLProtocol.recorder.requests.first?.request)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/teams/ABC123/events")
        XCTAssertEqual(request.url?.query, "since_hours=12")
    }

    func testAnnotateEventPostsLabelToNestedPath() async throws {
        StubURLProtocol.reset(statusCode: 204)
        let matchID = UUID()
        let eventID = Self.goldenA
        try await stubbedClient().annotateEvent(id: eventID, matchUUID: matchID, label: "great finish")

        let recorded = try XCTUnwrap(StubURLProtocol.recorder.requests.first)
        XCTAssertEqual(recorded.request.httpMethod, "POST")
        XCTAssertEqual(recorded.request.url?.path,
                       "/matches/\(matchID.uuidString)/events/\(eventID.uuidString)/annotation")
        let json = try jsonObject(try XCTUnwrap(recorded.body))
        XCTAssertEqual(json["label"] as? String, "great finish")
    }

    // MARK: - UploadQueue

    private func makeQueueDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploadqueue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func samplePayload() -> MatchPayload {
        MatchPayload(uuid: UUID(), recordedAt: Date(timeIntervalSince1970: 0),
                     coordinates: [[40, -83]], events: [], fieldUUID: nil, teamCode: "ABC123",
                     stats: MatchStats())
    }

    func testEnqueuePersistsAndReloads() throws {
        let directory = try makeQueueDirectory()
        let client = stubbedClient()
        let payload = samplePayload()

        let queue = UploadQueue(directory: directory, client: client)
        try queue.enqueue(match: payload)
        XCTAssertEqual(queue.pending.count, 1)
        XCTAssertEqual(queue.pending.first?.id, payload.uuid)

        let fileURL = directory.appendingPathComponent("uploads/\(payload.uuid.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // A fresh queue over the same directory loads the persisted item.
        let reloaded = UploadQueue(directory: directory, client: client)
        XCTAssertEqual(reloaded.pending.count, 1)
        XCTAssertEqual(reloaded.pending.first?.id, payload.uuid)
    }

    func testFlushSuccessClearsQueue() async throws {
        StubURLProtocol.reset(statusCode: 204)
        let directory = try makeQueueDirectory()
        let queue = UploadQueue(directory: directory, client: stubbedClient())
        let payload = samplePayload()
        try queue.enqueue(match: payload)

        let remaining = await queue.flush()
        XCTAssertEqual(remaining, 0)
        XCTAssertTrue(queue.pending.isEmpty)
        let fileURL = directory.appendingPathComponent("uploads/\(payload.uuid.uuidString).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testFlushFailureBacksOff() async throws {
        StubURLProtocol.reset(statusCode: 500)
        let directory = try makeQueueDirectory()
        let queue = UploadQueue(directory: directory, client: stubbedClient())
        try queue.enqueue(match: samplePayload())

        let before = Date()
        let remaining = await queue.flush()
        XCTAssertEqual(remaining, 1)

        let item = try XCTUnwrap(queue.pending.first)
        XCTAssertEqual(item.attempts, 1)
        XCTAssertNotNil(item.lastError)
        // First failure -> 60 * 2^1 = 120 s from now.
        XCTAssertEqual(item.nextAttempt.timeIntervalSince(before), 120, accuracy: 5)
    }

    func testFlushBackoffGrowsExponentially() async throws {
        StubURLProtocol.reset(statusCode: 500)
        let directory = try makeQueueDirectory()
        let queue = UploadQueue(directory: directory, client: stubbedClient())
        let payload = samplePayload()
        try queue.enqueue(match: payload)

        _ = await queue.flush()  // attempts -> 1, next attempt 120 s out

        // Force the persisted item due again, then reload and fail a second time.
        let fileURL = directory.appendingPathComponent("uploads/\(payload.uuid.uuidString).json")
        var stored = try Self.isoDecoder.decode(PendingUpload.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(stored.attempts, 1)
        stored.nextAttempt = Date(timeIntervalSince1970: 0)
        try Self.isoEncoder.encode(stored).write(to: fileURL)

        let reloaded = UploadQueue(directory: directory, client: stubbedClient())
        let before = Date()
        _ = await reloaded.flush()
        let item = try XCTUnwrap(reloaded.pending.first)
        XCTAssertEqual(item.attempts, 2)
        // Second failure -> 60 * 2^2 = 240 s.
        XCTAssertEqual(item.nextAttempt.timeIntervalSince(before), 240, accuracy: 5)
    }

    func testFlushFieldsDecodesArray() async throws {
        StubURLProtocol.reset(statusCode: 204)
        let directory = try makeQueueDirectory()
        let queue = UploadQueue(directory: directory, client: stubbedClient())

        let rectangle = OrientedRectangle(center: Coordinate2D(latitude: 40, longitude: -83),
                                          lengthMeters: 100, widthMeters: 60, headingDegrees: 10,
                                          corners: [])
        let field = FieldModel(id: UUID(), name: "Pitch", createdAt: Date(timeIntervalSince1970: 0),
                               outline: [], rectangle: rectangle, source: .inferred, observationCount: 1)
        try queue.enqueue(fields: [field])
        XCTAssertEqual(queue.pending.first?.kind, .fields)

        let remaining = await queue.flush()
        XCTAssertEqual(remaining, 0)
        let recorded = try XCTUnwrap(StubURLProtocol.recorder.requests.first)
        XCTAssertEqual(recorded.request.url?.path, "/devices/\(deviceID.uuidString)/fields")
    }
}
