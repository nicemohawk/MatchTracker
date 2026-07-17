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
