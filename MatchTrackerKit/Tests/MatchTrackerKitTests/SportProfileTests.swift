import XCTest
import CoreGraphics
@testable import MatchTrackerKit

final class SportProfileTests: XCTestCase {

    private let fieldCenter = Coordinate2D(latitude: 40.0, longitude: -83.0)

    /// Inverse of `FieldProjector.normalizedPoint`: normalized field point -> world coordinate.
    private func place(_ rect: OrientedRectangle, x: Double, y: Double) -> Coordinate2D {
        let frame = ENUFrame(reference: rect.center)
        let radians = rect.headingDegrees * .pi / 180
        let longAxis = CGPoint(x: sin(radians), y: cos(radians))
        let shortAxis = CGPoint(x: cos(radians), y: -sin(radians))
        let along = (x - 0.5) * rect.lengthMeters
        let across = (y - 0.5) * rect.widthMeters
        let east = along * Double(longAxis.x) + across * Double(shortAxis.x)
        let north = along * Double(longAxis.y) + across * Double(shortAxis.y)
        return frame.unproject(CGPoint(x: east, y: north))
    }

    // MARK: - Per-sport plausibility

    func testPlausibilityVariesBySport() {
        // A 100 m × 68 m pitch: rugby/soccer sized, far too wide for an ultimate field.
        let rugbySized = makeOrientedRectangle(center: fieldCenter, lengthMeters: 100, widthMeters: 68, headingDegrees: 0)

        XCTAssertTrue(FieldGeometry.isPlausiblePitch(rugbySized), "defaults to soccer, which accepts 100×68")
        XCTAssertTrue(FieldGeometry.isPlausiblePitch(rugbySized, sport: .soccer))
        XCTAssertTrue(FieldGeometry.isPlausiblePitch(rugbySized, sport: .rugby))
        XCTAssertFalse(FieldGeometry.isPlausiblePitch(rugbySized, sport: .ultimate), "68 m exceeds ultimate's 30–40 m width")

        // A narrow 100 m × 37 m field reads as ultimate but not rugby (too narrow).
        let ultimateSized = makeOrientedRectangle(center: fieldCenter, lengthMeters: 100, widthMeters: 37, headingDegrees: 0)
        XCTAssertTrue(FieldGeometry.isPlausiblePitch(ultimateSized, sport: .ultimate))
        XCTAssertFalse(FieldGeometry.isPlausiblePitch(ultimateSized, sport: .rugby), "37 m is narrower than rugby's 55 m minimum")

        // Aspect ratio guard stays general across sports.
        let square = makeOrientedRectangle(center: fieldCenter, lengthMeters: 100, widthMeters: 95, headingDegrees: 0)
        XCTAssertFalse(FieldGeometry.isPlausiblePitch(square, sport: .rugby), "aspect ratio 1.05 < 1.2")
    }

    func testSoccerRangesMatchLegacySanityCheck() {
        // The soccer preset must reproduce the legacy 60–130 m × 35–90 m bounds exactly.
        XCTAssertEqual(SportProfile.soccer.typicalLengthRange, 60...130)
        XCTAssertEqual(SportProfile.soccer.typicalWidthRange, 35...90)
    }

    func testWorkoutActivityRawValues() {
        // Verified HKWorkoutActivityType raw values (Kit stays HealthKit-free).
        XCTAssertEqual(SportProfile.soccer.workoutActivityTypeRawValue, 41)
        XCTAssertEqual(SportProfile.lacrosse.workoutActivityTypeRawValue, 27)
        XCTAssertEqual(SportProfile.fieldHockey.workoutActivityTypeRawValue, 25)
        XCTAssertEqual(SportProfile.rugby.workoutActivityTypeRawValue, 36)
        XCTAssertEqual(SportProfile.ultimate.workoutActivityTypeRawValue, 73)
    }

    // MARK: - Back-compatible decoding

    /// Old field JSON (pre multi-sport) had no `sportID` key; it must still decode, defaulting nil.
    func testOldFieldJSONStillDecodes() throws {
        struct LegacyField: Encodable {
            var id: UUID
            var name: String
            var createdAt: Date
            var outline: [Coordinate2D]
            var rectangle: OrientedRectangle
            var source: FieldSource
            var observationCount: Int
        }

        let rect = makeOrientedRectangle(center: fieldCenter, lengthMeters: 100, widthMeters: 64, headingDegrees: 30)
        let legacy = LegacyField(id: UUID(), name: "Old Pitch", createdAt: Date(timeIntervalSince1970: 1_000_000),
                                 outline: rect.corners, rectangle: rect, source: .trained, observationCount: 4)

        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sportID"), "legacy fixture must lack the new key")

        let decoded = try JSONDecoder().decode(FieldModel.self, from: data)
        XCTAssertNil(decoded.sportID, "missing sport_id decodes as nil == soccer")
        XCTAssertEqual(decoded.name, "Old Pitch")
        XCTAssertEqual(decoded.observationCount, 4)
    }

    /// Old match JSON had neither `sportID` nor `headings`; both must decode to nil.
    func testOldMatchRecordJSONStillDecodes() throws {
        struct LegacyMatchRecord: Encodable {
            var id: UUID
            var startDate: Date
            var endDate: Date?
            var fieldID: UUID?
            var events: [MatchEvent]
            var teamCode: String?
        }

        let legacy = LegacyMatchRecord(id: UUID(), startDate: Date(timeIntervalSince1970: 0),
                                       endDate: Date(timeIntervalSince1970: 3600), fieldID: UUID(),
                                       events: [MatchEvent(kind: .matchStart, date: Date(timeIntervalSince1970: 0))],
                                       teamCode: "REDS")

        let data = try JSONEncoder().encode(legacy)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("sportID"))
        XCTAssertFalse(json.contains("headings"))

        let decoded = try JSONDecoder().decode(MatchRecord.self, from: data)
        XCTAssertNil(decoded.sportID)
        XCTAssertNil(decoded.headings)
        XCTAssertEqual(decoded.teamCode, "REDS")
        XCTAssertEqual(decoded.events.count, 1)
    }

    // MARK: - Role-label mapping

    func testRoleLabelMappingForLacrosse() {
        // Soccer-shaped roles map onto lacrosse's ordered vocabulary.
        XCTAssertEqual(PositionAnalyzer.label(for: .goalkeeper, sport: .lacrosse), "goalie")
        XCTAssertEqual(PositionAnalyzer.label(for: .defender, sport: .lacrosse), "defense")
        XCTAssertEqual(PositionAnalyzer.label(for: .midfielder, sport: .lacrosse), "midfield")
        XCTAssertEqual(PositionAnalyzer.label(for: .forward, sport: .lacrosse), "attack")

        // Keeper-less sport: the continuum spans defender->forward across the whole vocabulary.
        XCTAssertEqual(PositionAnalyzer.label(for: .defender, sport: .rugby), "fullback")
        XCTAssertEqual(PositionAnalyzer.label(for: .midfielder, sport: .rugby), "halfback")
        XCTAssertEqual(PositionAnalyzer.label(for: .forward, sport: .rugby), "wing")

        // Soccer maps 1:1 to the enum's own names.
        XCTAssertEqual(PositionAnalyzer.label(for: .midfielder, sport: .soccer), "midfielder")
    }

    func testEstimatePopulatesLacrosseRoleLabel() {
        let rect = makeOrientedRectangle(center: fieldCenter, lengthMeters: 100, widthMeters: 55, headingDegrees: 0)
        let projector = FieldProjector(rectangle: rect)
        let start = Date(timeIntervalSince1970: 0)

        // A cloud clustered around midfield reads as a midfielder-equivalent role.
        var points: [TrackPoint] = []
        for i in 0..<120 {
            let x = 0.5 + 0.05 * sin(Double(i) * 0.4)
            let y = 0.5 + 0.05 * cos(Double(i) * 0.3)
            points.append(TrackPoint(coordinate: place(rect, x: x, y: y),
                                     timestamp: start.addingTimeInterval(Double(i)),
                                     speedMetersPerSecond: 2.0, courseDegrees: -1, horizontalAccuracy: 5))
        }
        let interval = DateInterval(start: start, end: start.addingTimeInterval(120))

        let estimate = PositionAnalyzer.estimate(points: points, projector: projector, events: [],
                                                 playingIntervals: [interval], sport: .lacrosse)

        XCTAssertTrue(SportProfile.lacrosse.positionRoles.contains(estimate.roleLabel),
                      "roleLabel must come from the lacrosse vocabulary")
        XCTAssertEqual(estimate.roleLabel, PositionAnalyzer.label(for: estimate.role, sport: .lacrosse))
    }
}
