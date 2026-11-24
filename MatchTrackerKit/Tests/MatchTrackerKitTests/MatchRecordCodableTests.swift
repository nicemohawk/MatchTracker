import XCTest
@testable import MatchTrackerKit

final class MatchRecordCodableTests: XCTestCase {

    /// A record carrying a redundant GPS track round-trips through the canonical JSON coders.
    func testRecordWithTrackRoundTrips() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<3).map { index in
            TrackPoint(
                coordinate: Coordinate2D(latitude: 40.0 + Double(index) * 0.0001, longitude: -83.0),
                timestamp: start.addingTimeInterval(Double(index)),
                speedMetersPerSecond: 2.5,
                courseDegrees: 90,
                horizontalAccuracy: 5
            )
        }
        let record = MatchRecord(
            id: UUID(),
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            fieldID: nil,
            events: [MatchEvent(kind: .matchStart, date: start)],
            teamCode: nil,
            track: points
        )

        let data = try MatchTrackerJSON.encoder().encode(record)
        let decoded = try MatchTrackerJSON.decoder().decode(MatchRecord.self, from: data)

        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.track?.count, points.count)
        XCTAssertEqual(decoded.track?.first?.coordinate, points.first?.coordinate)
        XCTAssertEqual(decoded.track?.last?.timestamp, points.last?.timestamp)
    }

    /// JSON written before the `track` field existed still decodes cleanly (track nil).
    func testOldRecordJSONWithoutTrackDecodes() throws {
        let json = """
        {
            "id": "6F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0",
            "startDate": "2025-06-01T14:00:00Z",
            "endDate": "2025-06-01T15:30:00Z",
            "events": []
        }
        """
        let decoded = try MatchTrackerJSON.decoder().decode(MatchRecord.self, from: Data(json.utf8))
        XCTAssertNil(decoded.track)
        XCTAssertEqual(decoded.id.uuidString, "6F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0")
    }
}

// MARK: - Backend timestamp decoding

extension MatchRecordCodableTests {
    /// The backend normalized every timestamp to ISO-8601 UTC with a trailing `Z`, in two
    /// precisions. The production decoder (`APIClient.jsonDecoder()`) must accept both.
    func testBackendDecoderAcceptsBothTimestampPrecisions() throws {
        struct WireSample: Codable {
            var recordedAt: Date
            var createdAt: Date
            enum CodingKeys: String, CodingKey {
                case recordedAt = "recorded_at"
                case createdAt = "created_at"
            }
        }
        let json = Data("""
        {"recorded_at": "2026-07-14T12:09:58.558671Z", "created_at": "2026-07-14T12:09:58Z"}
        """.utf8)

        let decoded = try APIClient.jsonDecoder().decode(WireSample.self, from: json)

        let expectedWhole = Date(timeIntervalSince1970: 1_784_030_998)  // 2026-07-14T12:09:58Z
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970,
                       expectedWhole.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.recordedAt.timeIntervalSince1970,
                       expectedWhole.timeIntervalSince1970 + 0.558671, accuracy: 0.001)
    }

    func testBackendDecoderRejectsGarbageTimestamp() {
        struct WireSample: Codable { var createdAt: Date
            enum CodingKeys: String, CodingKey { case createdAt = "created_at" } }
        let json = Data(#"{"created_at": "yesterday-ish"}"#.utf8)
        XCTAssertThrowsError(try APIClient.jsonDecoder().decode(WireSample.self, from: json))
    }
}

// MARK: - MatchLog journal

extension MatchRecordCodableTests {
    func testJournalPersistsEntriesAsJSONL() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        MatchLog.enableJournal(at: url, deviceTag: "test")
        MatchLog.info("alpha", category: "unit")
        MatchLog.error("beta", category: "unit")
        MatchLog.flushJournal()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        // enableJournal itself logs one line; then the two above.
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        let last = try XCTUnwrap(lines.last?.data(using: .utf8))
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: last) as? [String: String])
        XCTAssertEqual(decoded["d"], "test")
        XCTAssertEqual(decoded["l"], "error")
        XCTAssertEqual(decoded["c"], "unit")
        XCTAssertEqual(decoded["m"], "beta")
        XCTAssertNotNil(decoded["t"])
    }
}
