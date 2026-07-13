import XCTest
@testable import MatchTrackerKit

final class MatchTrackerKitTests: XCTestCase {

    func testFieldStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatchTrackerKitTests-\(UUID().uuidString)")
        let store = FieldStore(directory: directory)

        let outline = [
            Coordinate2D(latitude: 40.0, longitude: -83.0),
            Coordinate2D(latitude: 40.001, longitude: -83.0),
            Coordinate2D(latitude: 40.001, longitude: -82.999),
            Coordinate2D(latitude: 40.0, longitude: -82.999)
        ]
        let rectangle = FieldGeometry.fitOrientedRectangle(to: outline)
        let field = FieldModel(
            id: UUID(),
            name: "Test Pitch",
            createdAt: Date(),
            outline: outline,
            rectangle: try XCTUnwrap(rectangle),
            source: .trained,
            observationCount: 0
        )

        try store.save(field)

        let reloaded = FieldStore(directory: directory)
        try reloaded.load()
        XCTAssertEqual(reloaded.fields.count, 1)
        XCTAssertEqual(reloaded.fields.first?.id, field.id)
        XCTAssertEqual(reloaded.fields.first?.name, "Test Pitch")
        XCTAssertEqual(reloaded.fields.first?.source, .trained)

        try reloaded.delete(id: field.id)
        XCTAssertTrue(reloaded.fields.isEmpty)

        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordObservationProposesInferredField() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatchTrackerKitTests-\(UUID().uuidString)")
        let store = FieldStore(directory: directory)

        let track = (0..<10).map { index in
            TrackPoint(
                coordinate: Coordinate2D(latitude: 40.0 + Double(index) * 0.0001, longitude: -83.0 + Double(index) * 0.0001),
                timestamp: Date(timeIntervalSince1970: Double(index)),
                speedMetersPerSecond: -1,
                courseDegrees: -1,
                horizontalAccuracy: 5
            )
        }

        if case .proposed(let field) = store.recordObservation(track: track) {
            XCTAssertEqual(field.source, .inferred)
            XCTAssertTrue(store.fields.isEmpty, "proposed fields must not be auto-saved")
        } else {
            XCTFail("expected a proposed inferred field")
        }

        try? FileManager.default.removeItem(at: directory)
    }

    func testMatchPayloadWireShape() throws {
        let payload = MatchPayload(
            uuid: UUID(),
            recordedAt: Date(timeIntervalSince1970: 0),
            coordinates: [[40.0, -83.0], [40.001, -83.0]],
            events: [MatchEvent(kind: .goalMine, date: Date(timeIntervalSince1970: 60))],
            fieldUUID: UUID(),
            teamCode: "ABC",
            stats: MatchStats(totalDistanceMeters: 100)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let track = try XCTUnwrap(json["track"] as? [String: Any])
        XCTAssertNotNil(track["coordinates"] as? [[Double]])
        XCTAssertNotNil(json["recorded_at"] as? String)
        XCTAssertEqual(json["team_code"] as? String, "ABC")
        XCTAssertNotNil(json["field_uuid"])
        XCTAssertNotNil(json["stats"])
    }

    func testAnalyticsStubsCompile() {
        let report = WorkrateAnalyzer.analyze(track: [], runs: [], playingIntervals: [])
        XCTAssertEqual(report.totalDistanceMeters, 0)

        let rectangle = OrientedRectangle(
            center: Coordinate2D(latitude: 0, longitude: 0),
            lengthMeters: 100, widthMeters: 60, headingDegrees: 0,
            corners: [
                Coordinate2D(latitude: 0, longitude: 0),
                Coordinate2D(latitude: 0, longitude: 1),
                Coordinate2D(latitude: 1, longitude: 1),
                Coordinate2D(latitude: 1, longitude: 0)
            ]
        )
        let projector = FieldProjector(rectangle: rectangle)
        let grid = HeatmapGrid.compute(points: [], projector: projector, columns: 10, rows: 6, playingIntervals: nil)
        XCTAssertEqual(grid.cells.count, 60)
        XCTAssertEqual(grid[0, 0], 0)
    }
}
