import XCTest
import CoreGraphics
@testable import MatchTrackerKit

final class MatchTrackerKitTests: XCTestCase {

    // MARK: - Test support

    /// Deterministic PRNG so synthetic-data tests are stable across runs.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var x = state
            x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33
            return x
        }
    }

    private func gaussian(_ rng: inout SeededGenerator, mean: Double, sd: Double) -> Double {
        let u1 = Double.random(in: 1e-12...1, using: &rng)
        let u2 = Double.random(in: 0...1, using: &rng)
        return mean + sd * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    private let fieldCenter = Coordinate2D(latitude: 40.0, longitude: -83.0)

    /// Place a normalized field point (x along long axis, y along short) back into world coords.
    /// Exact inverse of `FieldProjector.normalizedPoint`.
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

    /// A rectangle built directly from parameters (canonical corners generated).
    private func rectangle(center: Coordinate2D, length: Double, width: Double, heading: Double) -> OrientedRectangle {
        makeOrientedRectangle(center: center, lengthMeters: length, widthMeters: width, headingDegrees: heading)
    }

    /// Absolute difference between two undirected bearings folded to 0..<180.
    private func headingDelta(_ a: Double, _ b: Double) -> Double {
        let raw = abs(foldHeading(a) - foldHeading(b))
        return min(raw, 180 - raw)
    }

    /// A track that fills a rectangle uniformly (players cover ~the whole pitch).
    private func occupancyTrack(_ rect: OrientedRectangle, count: Int, seed: UInt64,
                                accuracy: Double = 5, start: Date = Date(timeIntervalSince1970: 0)) -> [TrackPoint] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { index in
            let coordinate = place(rect, x: Double.random(in: 0...1, using: &rng), y: Double.random(in: 0...1, using: &rng))
            return TrackPoint(coordinate: coordinate,
                              timestamp: start.addingTimeInterval(Double(index)),
                              speedMetersPerSecond: -1, courseDegrees: -1, horizontalAccuracy: accuracy)
        }
    }

    // MARK: - Existing smoke tests (retained)

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

    func testFieldStoreReplaceAllSwapsContentsAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatchTrackerKitTests-\(UUID().uuidString)")
        let store = FieldStore(directory: directory)

        let stale = FieldModel(id: UUID(), name: "Stale", createdAt: Date(), outline: [],
                               rectangle: rectangle(center: fieldCenter, length: 90, width: 55, heading: 30),
                               source: .trained, observationCount: 1)
        let mirrored = FieldModel(id: UUID(), name: "Mirrored", createdAt: Date(), outline: [],
                                  rectangle: rectangle(center: fieldCenter, length: 100, width: 64, heading: 0),
                                  source: .trained, observationCount: 2)
        try store.save(stale)

        try store.replaceAll([mirrored])
        XCTAssertEqual(store.fields.map(\.id), [mirrored.id])

        let reloaded = FieldStore(directory: directory)
        try reloaded.load()
        XCTAssertEqual(reloaded.fields.map(\.id), [mirrored.id])
        XCTAssertEqual(reloaded.fields.first?.name, "Mirrored")

        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordObservationProposesInferredField() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatchTrackerKitTests-\(UUID().uuidString)")
        let store = FieldStore(directory: directory)

        // A field-shaped occupancy cloud (a straight line can't pass the pitch sanity checks).
        let rect = rectangle(center: fieldCenter, length: 100, width: 64, heading: 15)
        let track = occupancyTrack(rect, count: 200, seed: 11)

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

    func testMatchStatsWireKeys() throws {
        let report = WorkrateReport(
            totalDistanceMeters: 6423.5,
            distancePerMinute: [100, 110],
            speedZones: SpeedZones(standing: 210, walking: 890, jogging: 1340, running: 520, sprinting: 160),
            sprintCount: 14,
            runCount: 37,
            averageHeartRate: 152.3,
            timeOnPitch: 3120,
            workrateScore: 72.4
        )
        let position = PositionEstimate(role: .midfielder, side: .left, confidence: 0.8,
                                        meanPoint: .zero, periodMeanPoints: [])
        let payload = MatchPayload(
            uuid: UUID(),
            recordedAt: Date(timeIntervalSince1970: 0),
            coordinates: [[40.0, -83.0]],
            events: [],
            fieldUUID: UUID(),
            teamCode: "U14-RED",
            playerName: "Ben Lachman",
            stats: MatchStats(report: report, position: position)
        )

        let data = try MatchTrackerJSON.encoder().encode(payload)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["player_name"] as? String, "Ben Lachman")

        let stats = try XCTUnwrap(json["stats"] as? [String: Any])
        XCTAssertEqual(stats["total_distance_m"] as? Double, 6423.5)
        XCTAssertEqual(stats["time_on_pitch_s"] as? Double, 3120)
        XCTAssertEqual(stats["sprint_count"] as? Int, 14)
        XCTAssertEqual(stats["run_count"] as? Int, 37)
        XCTAssertEqual(stats["workrate_score"] as? Double, 72.4)
        XCTAssertEqual(stats["avg_hr"] as? Double, 152.3)
        XCTAssertEqual(stats["position_role"] as? String, "midfielder")
        XCTAssertEqual(stats["position_side"] as? String, "left")

        let zones = try XCTUnwrap(stats["speed_zones"] as? [String: Any])
        XCTAssertEqual(Set(zones.keys), ["standing_s", "walking_s", "jogging_s", "running_s", "sprinting_s"])
        XCTAssertEqual(zones["standing_s"] as? Double, 210)
        XCTAssertEqual(zones["walking_s"] as? Double, 890)
        XCTAssertEqual(zones["jogging_s"] as? Double, 1340)
        XCTAssertEqual(zones["running_s"] as? Double, 520)
        XCTAssertEqual(zones["sprinting_s"] as? Double, 160)

        // Round-trips back to an equal stats value.
        let decoded = try MatchTrackerJSON.decoder().decode(MatchPayload.self, from: data)
        XCTAssertEqual(decoded.playerName, "Ben Lachman")
        XCTAssertEqual(decoded.stats.speedZones.jogging, 1340)
        XCTAssertEqual(decoded.stats.positionRole, .midfielder)
        XCTAssertEqual(decoded.stats.positionSide, .left)
    }

    func testMatchStatsOmitsNilOptionalFields() throws {
        let payload = MatchPayload(
            uuid: UUID(), recordedAt: Date(timeIntervalSince1970: 0),
            coordinates: [], events: [], fieldUUID: nil, teamCode: nil,
            stats: MatchStats(report: WorkrateReport())
        )
        let data = try MatchTrackerJSON.encoder().encode(payload)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["player_name"], "nil player_name must be omitted")
        let stats = try XCTUnwrap(json["stats"] as? [String: Any])
        XCTAssertNil(stats["avg_hr"], "nil avg_hr must be omitted")
        XCTAssertNil(stats["position_role"])
        XCTAssertNil(stats["position_side"])
        // speed_zones is always present (zeros when empty).
        XCTAssertNotNil(stats["speed_zones"])
    }

    func testSpeedThresholdsDriveRunAndWorkrateConfig() {
        // Run detector defaults derive from the shared thresholds.
        let config = RunDetectorConfiguration()
        XCTAssertEqual(config.jogThreshold, SpeedThresholds.jogging)
        XCTAssertEqual(config.runThreshold, SpeedThresholds.running)
        XCTAssertEqual(config.sprintThreshold, SpeedThresholds.sprinting)

        // Workrate zone bucketing uses the same boundaries: a track held just under each
        // threshold lands entirely in the zone below it.
        func secondsInZones(speed: Double) -> SpeedZones {
            let track = speedTrack([Double](repeating: speed, count: 30))
            let playing = [DateInterval(start: track.first!.timestamp, end: track.last!.timestamp)]
            return WorkrateAnalyzer.analyze(track: track, runs: [], playingIntervals: playing).speedZones
        }
        XCTAssertGreaterThan(secondsInZones(speed: SpeedThresholds.walking - 0.1).standing, 0)
        XCTAssertGreaterThan(secondsInZones(speed: SpeedThresholds.jogging - 0.1).walking, 0)
        XCTAssertGreaterThan(secondsInZones(speed: SpeedThresholds.running - 0.1).jogging, 0)
        XCTAssertGreaterThan(secondsInZones(speed: SpeedThresholds.sprinting - 0.1).running, 0)
        XCTAssertGreaterThan(secondsInZones(speed: SpeedThresholds.sprinting + 0.1).sprinting, 0)
    }

    func testAnalyticsProduceGrid() {
        let rect = rectangle(center: fieldCenter, length: 100, width: 60, heading: 0)
        let projector = FieldProjector(rectangle: rect)
        let grid = HeatmapGrid.compute(points: [], projector: projector, columns: 10, rows: 6, playingIntervals: nil)
        XCTAssertEqual(grid.cells.count, 60)
        XCTAssertEqual(grid[0, 0], 0)
    }

    // MARK: - Rectangle fitting

    func testFitOrientedRectangleOnNoisyRotatedRectangle() {
        let trueLength = 105.0, trueWidth = 68.0, trueHeading = 25.0
        let frame = ENUFrame(reference: fieldCenter)
        var rng = SeededGenerator(seed: 42)

        // Sample the four edges with 1 m Gaussian noise.
        var coordinates: [Coordinate2D] = []
        let radians = trueHeading * .pi / 180
        let longAxis = CGPoint(x: sin(radians), y: cos(radians))
        let shortAxis = CGPoint(x: cos(radians), y: -sin(radians))
        func addPoint(along: Double, across: Double) {
            let east = along * Double(longAxis.x) + across * Double(shortAxis.x) + gaussian(&rng, mean: 0, sd: 1.0)
            let north = along * Double(longAxis.y) + across * Double(shortAxis.y) + gaussian(&rng, mean: 0, sd: 1.0)
            coordinates.append(frame.unproject(CGPoint(x: east, y: north)))
        }
        for step in stride(from: -trueLength / 2, through: trueLength / 2, by: 5) {
            addPoint(along: step, across: trueWidth / 2)
            addPoint(along: step, across: -trueWidth / 2)
        }
        for step in stride(from: -trueWidth / 2, through: trueWidth / 2, by: 5) {
            addPoint(along: trueLength / 2, across: step)
            addPoint(along: -trueLength / 2, across: step)
        }

        let fitted = FieldGeometry.fitOrientedRectangle(to: coordinates)
        let result = try! XCTUnwrap(fitted)

        XCTAssertEqual(result.lengthMeters, trueLength, accuracy: 5, "length off")
        XCTAssertEqual(result.widthMeters, trueWidth, accuracy: 5, "width off")
        XCTAssertLessThan(headingDelta(result.headingDegrees, trueHeading), 4, "heading off")
        XCTAssertLessThan(haversineMeters(result.center, fieldCenter), 4, "center off")
        XCTAssertGreaterThan(result.lengthMeters, result.widthMeters)
        XCTAssertTrue((0..<180).contains(result.headingDegrees))
    }

    func testSimplifyReducesCollinearRun() {
        // A nearly-straight run of points collapses to its endpoints.
        let frame = ENUFrame(reference: fieldCenter)
        let points = (0...20).map { frame.unproject(CGPoint(x: Double($0) * 5, y: 0)) }
        let simplified = FieldGeometry.simplify(points, toleranceMeters: 1.0)
        XCTAssertEqual(simplified.count, 2)
        XCTAssertEqual(simplified.first, points.first)
        XCTAssertEqual(simplified.last, points.last)

        // A corner is preserved.
        let elbow = [
            frame.unproject(CGPoint(x: 0, y: 0)),
            frame.unproject(CGPoint(x: 50, y: 0)),
            frame.unproject(CGPoint(x: 50, y: 50))
        ]
        let keptCorner = FieldGeometry.simplify(elbow, toleranceMeters: 1.0)
        XCTAssertEqual(keptCorner.count, 3)
    }

    // MARK: - Inference

    func testInferFieldRectangleIgnoresWarmupExcursion() {
        let rect = rectangle(center: fieldCenter, length: 100, width: 64, heading: 20)
        var track = occupancyTrack(rect, count: 294, seed: 7)

        // Warm-up: a handful of points ~150 m off one end (walking onto the pitch).
        var rng = SeededGenerator(seed: 99)
        for index in 0..<6 {
            let coordinate = place(rect, x: 2.0 + Double.random(in: 0...0.2, using: &rng), y: 0.5)
            track.append(TrackPoint(coordinate: coordinate,
                                    timestamp: Date(timeIntervalSince1970: Double(1000 + index)),
                                    speedMetersPerSecond: -1, courseDegrees: -1, horizontalAccuracy: 5))
        }

        let inferred = try! XCTUnwrap(FieldGeometry.inferFieldRectangle(from: track))
        XCTAssertEqual(inferred.lengthMeters, 105, accuracy: 12)   // ~100 * 1.05 expansion
        XCTAssertEqual(inferred.widthMeters, 67, accuracy: 10)
        XCTAssertLessThan(headingDelta(inferred.headingDegrees, 20), 8)
        XCTAssertLessThan(haversineMeters(inferred.center, fieldCenter), 12)
    }

    func testInferFieldRectangleRejectsNonFieldShapes() {
        // A straight line (zero width) is not field-shaped.
        let frame = ENUFrame(reference: fieldCenter)
        let line = (0..<40).map { index -> TrackPoint in
            TrackPoint(coordinate: frame.unproject(CGPoint(x: Double(index) * 3, y: 0)),
                       timestamp: Date(timeIntervalSince1970: Double(index)),
                       speedMetersPerSecond: -1, courseDegrees: -1, horizontalAccuracy: 5)
        }
        XCTAssertNil(FieldGeometry.inferFieldRectangle(from: line))

        // A tiny blob is too small to be a pitch.
        let tiny = rectangle(center: fieldCenter, length: 20, width: 12, heading: 0)
        let blob = occupancyTrack(tiny, count: 100, seed: 3)
        XCTAssertNil(FieldGeometry.inferFieldRectangle(from: blob))

        // Too few points to trust.
        XCTAssertNil(FieldGeometry.inferFieldRectangle(from: Array(blob.prefix(4))))
    }

    // MARK: - Projector round trips

    func testProjectorRoundTrip() {
        let rect = rectangle(center: fieldCenter, length: 105, width: 68, heading: 40)
        let projector = FieldProjector(rectangle: rect)
        for x in stride(from: 0.1, through: 0.9, by: 0.2) {
            for y in stride(from: 0.1, through: 0.9, by: 0.2) {
                let coordinate = place(rect, x: x, y: y)
                let normalized = try! XCTUnwrap(projector.normalizedPoint(for: coordinate))
                XCTAssertEqual(Double(normalized.x), x, accuracy: 0.01)
                XCTAssertEqual(Double(normalized.y), y, accuracy: 0.01)
            }
        }
    }

    func testProjectorRejectsFarPoints() {
        let rect = rectangle(center: fieldCenter, length: 105, width: 68, heading: 0)
        let projector = FieldProjector(rectangle: rect)

        // 40 m beyond the end -> nil.
        let farAway = place(rect, x: 1.0 + 40.0 / rect.lengthMeters, y: 0.5)
        XCTAssertNil(projector.normalizedPoint(for: farAway))
        XCTAssertFalse(projector.contains(farAway, toleranceMeters: 10))

        // 5 m beyond the end -> inside the 20 m normalization tolerance, and within 10 m contains.
        let justOutside = place(rect, x: 1.0 + 5.0 / rect.lengthMeters, y: 0.5)
        XCTAssertNotNil(projector.normalizedPoint(for: justOutside))
        XCTAssertTrue(projector.contains(justOutside, toleranceMeters: 10))
        XCTAssertFalse(projector.contains(justOutside, toleranceMeters: 2))

        XCTAssertTrue(projector.contains(rect.center, toleranceMeters: 0))
    }

    // MARK: - Field matching / disambiguation

    private func makeField(_ rect: OrientedRectangle, name: String) -> FieldModel {
        FieldModel(id: UUID(), name: name, createdAt: Date(), outline: [], rectangle: rect,
                   source: .trained, observationCount: 1)
    }

    private func samples(_ rect: OrientedRectangle, seed: UInt64, count: Int = 200) -> [Coordinate2D] {
        var rng = SeededGenerator(seed: seed)
        // Fill close to the touchlines so a rotated field's corners fall outside a concentric
        // aligned field (that's what lets the fraction-inside score disambiguate them).
        return (0..<count).map { _ in
            place(rect, x: Double.random(in: 0.03...0.97, using: &rng), y: Double.random(in: 0.03...0.97, using: &rng))
        }
    }

    func testBestMatchDisambiguatesSideBySideFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatchTrackerKitTests-\(UUID().uuidString)")
        let store = FieldStore(directory: directory)

        // Two adjacent pitches separated ~75 m along the short axis.
        let fieldA = rectangle(center: fieldCenter, length: 105, width: 68, heading: 0)
        let eastCenter = place(fieldA, x: 0.5, y: 0.5 + 75.0 / fieldA.widthMeters)
        let fieldB = rectangle(center: eastCenter, length: 105, width: 68, heading: 0)

        try store.save(makeField(fieldA, name: "A"))
        try store.save(makeField(fieldB, name: "B"))

        XCTAssertEqual(store.bestMatch(for: samples(fieldA, seed: 1))?.name, "A")
        XCTAssertEqual(store.bestMatch(for: samples(fieldB, seed: 2))?.name, "B")

        try? FileManager.default.removeItem(at: directory)
    }

    func testBestMatchDisambiguatesRotatedOverlappingFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatchTrackerKitTests-\(UUID().uuidString)")
        let store = FieldStore(directory: directory)

        // Same center, one rotated 30 deg from the other.
        let aligned = rectangle(center: fieldCenter, length: 105, width: 68, heading: 0)
        let rotated = rectangle(center: fieldCenter, length: 105, width: 68, heading: 30)
        try store.save(makeField(aligned, name: "aligned"))
        try store.save(makeField(rotated, name: "rotated"))

        XCTAssertEqual(store.bestMatch(for: samples(aligned, seed: 5))?.name, "aligned")
        XCTAssertEqual(store.bestMatch(for: samples(rotated, seed: 6))?.name, "rotated")

        try? FileManager.default.removeItem(at: directory)
    }

    func testBestMatchReturnsNilForDistantTrack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatchTrackerKitTests-\(UUID().uuidString)")
        let store = FieldStore(directory: directory)
        let fieldA = rectangle(center: fieldCenter, length: 105, width: 68, heading: 0)
        try store.save(makeField(fieldA, name: "A"))

        let elsewhere = rectangle(center: Coordinate2D(latitude: 41.0, longitude: -84.0),
                                  length: 105, width: 68, heading: 0)
        XCTAssertNil(store.bestMatch(for: samples(elsewhere, seed: 8)))

        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordObservationRefinesMatchedField() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatchTrackerKitTests-\(UUID().uuidString)")
        let store = FieldStore(directory: directory)

        let stored = rectangle(center: fieldCenter, length: 100, width: 64, heading: 10)
        var field = makeField(stored, name: "Home")
        field.observationCount = 3
        try store.save(field)

        // A new match slightly longer than the stored geometry.
        let observed = rectangle(center: fieldCenter, length: 110, width: 64, heading: 10)
        let track = occupancyTrack(observed, count: 260, seed: 21)

        guard case .matched(let refined) = store.recordObservation(track: track) else {
            return XCTFail("expected a matched field")
        }
        XCTAssertEqual(refined.observationCount, 4)
        // Weighted toward the stored geometry (weight 3) but nudged longer by the observation.
        XCTAssertGreaterThan(refined.rectangle.lengthMeters, 100)
        XCTAssertLessThan(refined.rectangle.lengthMeters, 110)
        XCTAssertEqual(store.fields.first?.observationCount, 4, "refinement must be persisted")

        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Substitution intervals

    private func event(_ kind: MatchEventKind, _ seconds: TimeInterval) -> MatchEvent {
        MatchEvent(kind: kind, date: Date(timeIntervalSince1970: seconds))
    }

    func testPlayingIntervalsStartsOnPitch() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 1000)
        let events = [event(.subOut, 400), event(.subIn, 600)]
        let intervals = SubstitutionTracker.playingIntervals(events: events, matchStart: start, matchEnd: end)
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals[0].start, start)
        XCTAssertEqual(intervals[0].end.timeIntervalSince1970, 400)
        XCTAssertEqual(intervals[1].start.timeIntervalSince1970, 600)
        XCTAssertEqual(intervals[1].end, end)
        XCTAssertEqual(SubstitutionTracker.timeOnPitch(events: events, matchStart: start, matchEnd: end), 800)
    }

    func testPlayingIntervalsStartsOnBenchWhenFirstEventIsSubIn() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 1000)
        let events = [event(.subIn, 300), event(.subOut, 800)]
        let intervals = SubstitutionTracker.playingIntervals(events: events, matchStart: start, matchEnd: end)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].start.timeIntervalSince1970, 300)
        XCTAssertEqual(intervals[0].end.timeIntervalSince1970, 800)
    }

    func testPlayingIntervalsIgnoresDuplicatesAndTrailsToEnd() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 1000)
        // Duplicate subOut (already off) and duplicate subIn (already on) are ignored.
        let events = [event(.subOut, 200), event(.subOut, 250), event(.subIn, 500), event(.subIn, 550)]
        let intervals = SubstitutionTracker.playingIntervals(events: events, matchStart: start, matchEnd: end)
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals[0].end.timeIntervalSince1970, 200)
        XCTAssertEqual(intervals[1].start.timeIntervalSince1970, 500)
        XCTAssertEqual(intervals[1].end, end, "unpaired subIn runs to matchEnd")
    }

    func testPlayingIntervalsWholeMatchWithNoSubs() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 1000)
        let intervals = SubstitutionTracker.playingIntervals(events: [], matchStart: start, matchEnd: end)
        XCTAssertEqual(intervals, [DateInterval(start: start, end: end)])
    }

    // MARK: - Heatmap

    func testHeatmapNormalizationAndBenchExclusion() {
        let rect = rectangle(center: fieldCenter, length: 100, width: 60, heading: 0)
        let projector = FieldProjector(rectangle: rect)

        var points: [TrackPoint] = []
        // Dense cluster near the center (many samples -> busiest cell).
        for index in 0..<40 {
            points.append(TrackPoint(coordinate: place(rect, x: 0.5, y: 0.5),
                                     timestamp: Date(timeIntervalSince1970: Double(index)),
                                     speedMetersPerSecond: 1, courseDegrees: -1, horizontalAccuracy: 5))
        }
        // Bench excursion, timestamped later (excluded by playing intervals). Placed at a cell
        // interior (0.25, 0.25) to avoid ambiguous cell-boundary rounding.
        for index in 0..<10 {
            points.append(TrackPoint(coordinate: place(rect, x: 0.25, y: 0.25),
                                     timestamp: Date(timeIntervalSince1970: Double(500 + index)),
                                     speedMetersPerSecond: 1, courseDegrees: -1, horizontalAccuracy: 5))
        }

        let playing = [DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100))]
        let grid = HeatmapGrid.compute(points: points, projector: projector, columns: 10, rows: 6, playingIntervals: playing)

        XCTAssertEqual(grid.cells.max(), 1.0, "busiest cell must normalize to 1")
        XCTAssertEqual(grid[5, 3], 1.0, "center cell is the hot spot")
        XCTAssertEqual(grid[2, 1], 0.0, "bench-time samples are excluded")

        // Without exclusion the bench cell lights up.
        let gridAll = HeatmapGrid.compute(points: points, projector: projector, columns: 10, rows: 6, playingIntervals: nil)
        XCTAssertGreaterThan(gridAll[2, 1], 0.0)
    }

    // MARK: - Run detection

    /// Build a track with prescribed per-point speeds, 1 s apart, advancing east.
    private func speedTrack(_ speeds: [Double], usePointSpeed: Bool = true,
                            start: Date = Date(timeIntervalSince1970: 0)) -> [TrackPoint] {
        let frame = ENUFrame(reference: fieldCenter)
        var east = 0.0
        var points: [TrackPoint] = []
        for (index, speed) in speeds.enumerated() {
            let coordinate = frame.unproject(CGPoint(x: east, y: 0))
            points.append(TrackPoint(coordinate: coordinate,
                                     timestamp: start.addingTimeInterval(Double(index)),
                                     speedMetersPerSecond: usePointSpeed ? speed : -1,
                                     courseDegrees: -1, horizontalAccuracy: 5))
            east += speed // dt = 1 s
        }
        return points
    }

    func testRunDetectionCountsRunsAndSprints() {
        // walk, a run (~4.5), rest, a sprint (~6.0), rest.
        var speeds = [Double](repeating: 0.5, count: 5)
        speeds += [Double](repeating: 4.5, count: 8)
        speeds += [Double](repeating: 0.5, count: 4)
        speeds += [Double](repeating: 6.0, count: 8)
        speeds += [Double](repeating: 0.5, count: 5)

        let runs = RunDetector.detectRuns(in: speedTrack(speeds), configuration: RunDetectorConfiguration())
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.filter { $0.intensity == .sprint }.count, 1)
        XCTAssertEqual(runs.filter { $0.intensity == .run }.count, 1)
        XCTAssertGreaterThan(runs[0].distanceMeters, 0)
        XCTAssertGreaterThanOrEqual(runs[1].peakSpeed, 5.5)
    }

    func testRunDetectionDropsShortSpike() {
        // A brief burst shorter than the minimum run duration is dropped.
        let speeds = [0.5, 0.5, 6.0, 0.5, 0.5]
        var config = RunDetectorConfiguration()
        config.minimumDuration = 3
        let runs = RunDetector.detectRuns(in: speedTrack(speeds), configuration: config)
        XCTAssertTrue(runs.isEmpty)
    }

    func testRunDetectionMergesAcrossShortGap() {
        // Two runs split by a 3 s dip.
        var speeds = [Double](repeating: 4.5, count: 5)
        speeds += [Double](repeating: 0.0, count: 3)
        speeds += [Double](repeating: 4.5, count: 5)
        let track = speedTrack(speeds)

        let separate = RunDetector.detectRuns(in: track, configuration: RunDetectorConfiguration())
        XCTAssertEqual(separate.count, 2, "3 s gap exceeds the default merge gap")

        var merging = RunDetectorConfiguration()
        merging.mergeGap = 6
        let merged = RunDetector.detectRuns(in: track, configuration: merging)
        XCTAssertEqual(merged.count, 1, "a larger merge gap joins the two runs")
    }

    func testRunDetectionUsesDerivedSpeedWhenInvalid() {
        // No point speed supplied; detector must derive it from positions.
        var speeds = [Double](repeating: 0.5, count: 5)
        speeds += [Double](repeating: 5.0, count: 8)
        speeds += [Double](repeating: 0.5, count: 5)
        let runs = RunDetector.detectRuns(in: speedTrack(speeds, usePointSpeed: false),
                                          configuration: RunDetectorConfiguration())
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.intensity, .run)
    }

    // MARK: - Workrate

    func testWorkrateZonesAndScore() {
        var speeds = [Double](repeating: 0.2, count: 60)   // standing
        speeds += [Double](repeating: 1.0, count: 60)      // walking
        speeds += [Double](repeating: 4.5, count: 60)      // running
        speeds += [Double](repeating: 6.0, count: 60)      // sprinting
        let track = speedTrack(speeds)
        let playing = [DateInterval(start: track.first!.timestamp, end: track.last!.timestamp)]
        let runs = RunDetector.detectRuns(in: track, configuration: RunDetectorConfiguration())

        let report = WorkrateAnalyzer.analyze(track: track, runs: runs, playingIntervals: playing)

        XCTAssertEqual(report.speedZones.standing, 60, accuracy: 3)
        XCTAssertEqual(report.speedZones.walking, 60, accuracy: 3)
        XCTAssertEqual(report.speedZones.running, 60, accuracy: 3)
        XCTAssertEqual(report.speedZones.sprinting, 60, accuracy: 3)
        XCTAssertEqual(report.speedZones.jogging, 0, accuracy: 3)

        // Distance ~= integral of speed over time.
        let expectedDistance = (0.2 + 1.0 + 4.5 + 6.0) * 60
        XCTAssertEqual(report.totalDistanceMeters, expectedDistance, accuracy: 40)

        XCTAssertGreaterThanOrEqual(report.sprintCount, 1)
        XCTAssertGreaterThanOrEqual(report.runCount, report.sprintCount)
        XCTAssertGreaterThan(report.workrateScore, 0)
        XCTAssertLessThanOrEqual(report.workrateScore, 100)
        XCTAssertEqual(report.distancePerMinute.count, 4, "≈4 minutes on pitch")
        XCTAssertEqual(report.timeOnPitch, 239, accuracy: 1)
    }

    // MARK: - Position

    /// A clustered normalized cloud mapped into world coords over a time window.
    private func positionTrack(_ rect: OrientedRectangle, meanX: Double, sdX: Double,
                               meanY: Double, sdY: Double, count: Int, seed: UInt64,
                               start: Date) -> [TrackPoint] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { index in
            let x = min(max(gaussian(&rng, mean: meanX, sd: sdX), 0.001), 0.999)
            let y = min(max(gaussian(&rng, mean: meanY, sd: sdY), 0.001), 0.999)
            return TrackPoint(coordinate: place(rect, x: x, y: y),
                              timestamp: start.addingTimeInterval(Double(index)),
                              speedMetersPerSecond: 2, courseDegrees: -1, horizontalAccuracy: 5)
        }
    }

    private func fullMatchInterval(_ track: [TrackPoint]) -> [DateInterval] {
        [DateInterval(start: track.first!.timestamp, end: track.last!.timestamp)]
    }

    func testPositionEstimateGoalkeeper() {
        let rect = rectangle(center: fieldCenter, length: 105, width: 68, heading: 0)
        let projector = FieldProjector(rectangle: rect)
        let track = positionTrack(rect, meanX: 0.05, sdX: 0.02, meanY: 0.5, sdY: 0.02,
                                  count: 200, seed: 31, start: Date(timeIntervalSince1970: 0))
        let estimate = PositionAnalyzer.estimate(points: track, projector: projector,
                                                  events: [], playingIntervals: fullMatchInterval(track))
        XCTAssertEqual(estimate.role, .goalkeeper)
        XCTAssertEqual(estimate.side, .center)
        XCTAssertGreaterThan(estimate.confidence, 0.6)
    }

    func testPositionEstimateLeftBack() {
        let rect = rectangle(center: fieldCenter, length: 105, width: 68, heading: 0)
        let projector = FieldProjector(rectangle: rect)
        let track = positionTrack(rect, meanX: 0.25, sdX: 0.035, meanY: 0.25, sdY: 0.03,
                                  count: 200, seed: 32, start: Date(timeIntervalSince1970: 0))
        let estimate = PositionAnalyzer.estimate(points: track, projector: projector,
                                                  events: [], playingIntervals: fullMatchInterval(track))
        XCTAssertEqual(estimate.role, .defender)
        XCTAssertEqual(estimate.side, .left)
    }

    func testPositionEstimateStriker() {
        let rect = rectangle(center: fieldCenter, length: 105, width: 68, heading: 0)
        let projector = FieldProjector(rectangle: rect)
        let track = positionTrack(rect, meanX: 0.82, sdX: 0.10, meanY: 0.5, sdY: 0.06,
                                  count: 200, seed: 33, start: Date(timeIntervalSince1970: 0))
        let estimate = PositionAnalyzer.estimate(points: track, projector: projector,
                                                  events: [], playingIntervals: fullMatchInterval(track))
        XCTAssertEqual(estimate.role, .forward)
    }

    func testPositionEstimateMidfielder() {
        let rect = rectangle(center: fieldCenter, length: 105, width: 68, heading: 0)
        let projector = FieldProjector(rectangle: rect)
        let track = positionTrack(rect, meanX: 0.5, sdX: 0.09, meanY: 0.5, sdY: 0.08,
                                  count: 200, seed: 34, start: Date(timeIntervalSince1970: 0))
        let estimate = PositionAnalyzer.estimate(points: track, projector: projector,
                                                  events: [], playingIntervals: fullMatchInterval(track))
        XCTAssertEqual(estimate.role, .midfielder)
    }

    func testPositionSecondHalfFlipIsCorrected() {
        let rect = rectangle(center: fieldCenter, length: 105, width: 68, heading: 0)
        let projector = FieldProjector(rectangle: rect)

        // First half: left back near (0.25, 0.25).
        let firstHalf = positionTrack(rect, meanX: 0.25, sdX: 0.035, meanY: 0.25, sdY: 0.03,
                                      count: 150, seed: 41, start: Date(timeIntervalSince1970: 0))
        // Second half: teams switch ends, so raw positions mirror to (0.75, 0.75).
        let secondHalf = positionTrack(rect, meanX: 0.75, sdX: 0.035, meanY: 0.75, sdY: 0.03,
                                       count: 150, seed: 42, start: Date(timeIntervalSince1970: 2000))
        let track = firstHalf + secondHalf

        let events = [
            event(.periodStart, 0), event(.periodEnd, 150),
            event(.periodStart, 2000), event(.periodEnd, 2150)
        ]
        let playing = [
            DateInterval(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 150)),
            DateInterval(start: Date(timeIntervalSince1970: 2000), end: Date(timeIntervalSince1970: 2150))
        ]

        let estimate = PositionAnalyzer.estimate(points: track, projector: projector,
                                                  events: events, playingIntervals: playing)
        // Flip correction should recover a consistent left-back, not a phantom midfielder.
        XCTAssertEqual(estimate.role, .defender)
        XCTAssertEqual(estimate.side, .left)
        XCTAssertEqual(estimate.periodMeanPoints.count, 2)
        for mean in estimate.periodMeanPoints {
            XCTAssertEqual(Double(mean.x), 0.25, accuracy: 0.08)
            XCTAssertEqual(Double(mean.y), 0.25, accuracy: 0.08)
        }
    }
}
