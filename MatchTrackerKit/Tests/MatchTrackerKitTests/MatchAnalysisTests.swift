import XCTest
import CoreGraphics
@testable import MatchTrackerKit

final class MatchAnalysisTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let rectangle = makeOrientedRectangle(center: Coordinate2D(latitude: 40, longitude: -83),
                                                  lengthMeters: 100, widthMeters: 60, headingDegrees: 30)
    private lazy var field = FieldModel(id: UUID(), name: "Home", createdAt: start, outline: [], rectangle: rectangle,
                                        source: .trained, observationCount: 1)

    private func place(long: Double, short: Double) -> Coordinate2D {
        let frame = ENUFrame(reference: rectangle.center)
        let radians = rectangle.headingDegrees * .pi / 180
        let along = (long - 0.5) * rectangle.lengthMeters, across = (short - 0.5) * rectangle.widthMeters
        return frame.unproject(CGPoint(x: along * sin(radians) + across * cos(radians),
                                       y: along * cos(radians) - across * sin(radians)))
    }

    private func point(_ second: Double, long: Double, short: Double = 0.5, speed: Double = 1.5) -> TrackPoint {
        TrackPoint(coordinate: place(long: long, short: short), timestamp: start.addingTimeInterval(second),
                   speedMetersPerSecond: speed, courseDegrees: -1, horizontalAccuracy: 5)
    }

    /// 40 minutes attacking the high end from the left, ten minutes standing, 40 attacking the low
    /// end — from the right as the field is laid out, which is still the player's left.
    private func twoHalves() -> [TrackPoint] {
        (0..<(90 * 60)).map { second in
            let wobble = 0.1 * sin(Double(second) / 40)
            switch second {
            case ..<2400: return point(Double(second), long: 0.7 + wobble, short: 0.2)
            case ..<3000: return point(Double(second), long: 0.5, short: 0.5, speed: 0)
            default: return point(Double(second), long: 0.3 + wobble, short: 0.8)
            }
        }
    }

    private func analyze(_ track: [TrackPoint], format: MatchFormat = .match, events: [MatchEvent] = [],
                         positions: [ReportedPosition]? = nil, flips: Bool? = nil, minutes: Double = 90,
                         heartRate: [HeartRateSample] = [], health: Double? = nil) throws -> MatchAnalytics {
        try XCTUnwrap(MatchAnalyzer.analyze(MatchAnalysisInput(
            interval: DateInterval(start: start, duration: minutes * 60), format: format, events: events,
            reportedPositions: positions, flipsAttack: flips, track: track, heartRate: heartRate,
            healthDistanceMeters: health, savedField: field)))
    }

    // MARK: - Direction

    func testSecondHalfIsTurnedAround() throws {
        let analytics = try analyze(twoHalves(), positions: [ReportedPosition(role: .forward)])
        XCTAssertEqual(try XCTUnwrap(analytics.halftime).start.timeIntervalSince(start), 2400, accuracy: 40)
        XCTAssertTrue(analytics.isDirectionConfident)
        // Halftime's edges are only known to the nearest half minute.
        let played = analytics.pitchPath.filter { $0.onPitch && !(2340...3060).contains($0.t) }
        XCTAssertTrue(played.allSatisfy { $0.y > 0.55 && $0.x < 0.3 }, "both halves attack up, from the left")
        XCTAssertEqual(try XCTUnwrap(analytics.thirds).defensive, 0, accuracy: 0.01)
        XCTAssertFalse(analytics.heat[(analytics.heat.count / 2)...].contains { $0 > 0.2 }, "row 0 is the attacking end")
    }

    func testPickupIsNotTurnedAround() throws {
        let analytics = try analyze(twoHalves(), format: .smallSided)
        XCTAssertNil(analytics.halftime)
        XCTAssertFalse(analytics.isDirectionConfident)
        XCTAssertLessThan(try XCTUnwrap(analytics.pitchPath.last).y, 0.5)
    }

    func testDefenderEvidenceFlipsTheDirection() throws {
        let analytics = try analyze(twoHalves(), positions: [ReportedPosition(role: .defender)])
        XCTAssertTrue(analytics.attackDirection.flipsAttack)
        XCTAssertTrue(analytics.pitchPath.filter { $0.onPitch && !(2340...3060).contains($0.t) }.allSatisfy { $0.y < 0.45 })
    }

    func testScoringSettlesTheDirection() throws {
        let track = twoHalves()
        let goal = MatchEvent(kind: .goalMine, date: start.addingTimeInterval(100))
        XCTAssertTrue(try analyze(track, events: [goal]).isDirectionConfident)
        XCTAssertFalse(try analyze(track, events: [goal]).attackDirection.flipsAttack)
        XCTAssertFalse(try analyze(track).isDirectionConfident)
    }

    func testTheWearersAnswerWins() throws {
        let analytics = try analyze(twoHalves(), positions: [ReportedPosition(role: .forward)], flips: true)
        XCTAssertTrue(analytics.attackDirection.flipsAttack)
        XCTAssertTrue(analytics.isDirectionConfident)
        XCTAssertFalse(try analyze(twoHalves(), flips: false).attackDirection.flipsAttack)
    }

    func testTwoHalvesWithoutAHalftimeAreNeverConfident() throws {
        let track = twoHalves().map { point in
            var point = point
            point.speedMetersPerSecond = 1.5
            return point
        }
        XCTAssertFalse(try analyze(track, positions: [ReportedPosition(role: .forward)], flips: true).isDirectionConfident)
    }

    func testPathIsDecimated() throws {
        let path = try analyze(twoHalves()).pitchPath
        XCTAssertEqual(Double(path.count), 2700, accuracy: 30)
        XCTAssertEqual(path.first?.t, 0)
    }

    // MARK: - One number each

    func testDistanceIsHealthKitsWhenThereIsOne() throws {
        let analytics = try analyze(twoHalves(), health: 6400)
        XCTAssertEqual(analytics.distanceMeters, 6400)
        XCTAssertEqual(analytics.workrate.totalDistanceMeters, 6400)
        XCTAssertEqual(analytics.metersPerMinute.reduce(0, +), 6400, accuracy: 0.1)
        XCTAssertEqual(analytics.metersPerMinute.count, 90)
        XCTAssertEqual(try XCTUnwrap(try analyze(twoHalves()).distanceMeters), 80 * 60 * 1.5, accuracy: 10)
    }

    func testHalftimeIsNotTimeOnPitch() throws {
        XCTAssertEqual(try analyze(twoHalves()).workrate.timeOnPitch / 60, 80, accuracy: 1)
    }

    func testTrimDecidesWhatCounts() throws {
        let heartRate = (0..<90).map { HeartRateSample(date: start.addingTimeInterval(Double($0) * 60), bpm: $0 <= 40 ? 150 : 90) }
        let analytics = try analyze(twoHalves(), minutes: 40, heartRate: heartRate)
        XCTAssertEqual(try XCTUnwrap(analytics.distanceMeters), 2400 * 1.5, accuracy: 10)
        XCTAssertEqual(analytics.averageHeartRate, 150)
    }

    func testTopSpeedAndRunsStopAtTheTouchline() throws {
        var track = twoHalves()
        for index in 100..<110 { track[index].speedMetersPerSecond = 6.5 }
        for index in 200..<210 {
            track[index].speedMetersPerSecond = 9
            track[index].coordinate = place(long: 1.4, short: 0.5)
        }
        let analytics = try analyze(track)
        XCTAssertEqual(analytics.topSpeedMetersPerSecond, 6.5)
        XCTAssertEqual(analytics.runs.sprintCount, 1)
        XCTAssertEqual(analytics.keyRuns.first?.peakSpeed, analytics.topSpeedMetersPerSecond)
        XCTAssertEqual(analytics.keyRuns.first?.points.isEmpty, false)
    }

    func testForgottenRecordingStopsCountingWithThePlay() throws {
        let track = twoHalves() + (5400..<30_000).filter { $0.isMultiple(of: 6) }.map {
            point(Double($0), long: 0.5, speed: -1)
        }
        XCTAssertLessThan(try analyze(track, minutes: 500).workrate.timeOnPitch / 60, 85)
    }

    func testWithoutARouteOnlyHeartRateSpeaks() throws {
        let heartRate = (0..<600).map { HeartRateSample(date: start.addingTimeInterval(Double($0) * 5), bpm: 150) }
        let analytics = try analyze([], heartRate: heartRate, health: 5000)
        XCTAssertFalse(analytics.hasRoute)
        let digest = MatchDigest(id: UUID(), interval: analytics.interval, format: .match, record: nil, analytics: analytics)
        XCTAssertNil(digest.topSpeedMetersPerSecond)
        XCTAssertNil(digest.sprintCount)
        XCTAssertNil(digest.heat)
        XCTAssertNotNil(digest.effort)
        XCTAssertEqual(digest.distanceMeters, 5000)
        XCTAssertNil(MatchAnalyzer.analyze(MatchAnalysisInput(interval: analytics.interval, format: .match)))
    }

    // MARK: - Digest

    func testDigestMatchesTheAnalysis() throws {
        let analytics = try analyze(twoHalves(), health: 6400)
        var record = MatchRecord(id: UUID(), startDate: start, endDate: nil, fieldID: nil, events: [
            MatchEvent(kind: .goalMine, date: start), MatchEvent(kind: .goalAgainstUs, date: start)
        ], teamCode: nil)
        record.opponent = "Rovers"
        let digest = MatchDigest(id: record.id, interval: analytics.interval, format: .match, record: record, analytics: analytics)
        XCTAssertEqual(digest.distanceMeters, analytics.distanceMeters)
        XCTAssertEqual(digest.topSpeedMetersPerSecond, analytics.topSpeedMetersPerSecond)
        XCTAssertEqual(digest.fieldName, "Home")
        XCTAssertEqual(digest.opponent, "Rovers")
        XCTAssertEqual(digest.result, .drawn)
        XCTAssertEqual(digest.heat?.count, 12 * 18)
        XCTAssertEqual(digest.heat?.max(), 1)
        XCTAssertEqual(try JSONDecoder().decode(MatchDigest.self, from: JSONEncoder().encode(digest)), digest)
    }

    func testOldDigestsStillDecode() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            MatchDigest(id: UUID(), startDate: start, endDate: start, format: .match))) as? [String: Any])
        object["heat"] = nil
        object["heatIsDirected"] = nil
        XCTAssertNoThrow(try JSONDecoder().decode(MatchDigest.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testCacheEntryGoesStaleWithItsRecordOrItsField() throws {
        var record = MatchRecord(id: UUID(), startDate: start, endDate: start.addingTimeInterval(5400), fieldID: nil, events: [], teamCode: nil)
        let digest = MatchDigest(id: record.id, startDate: start, endDate: start, format: .match)
        var cache = DigestCache()
        cache.entries[record.id] = .init(digest: digest, record: record, center: rectangle.center, fields: [field])
        cache = try JSONDecoder().decode(DigestCache.self, from: JSONEncoder().encode(cache))
        XCTAssertTrue(cache.isCurrent(record.id, record: record, fields: [field]))

        var far = field
        far.rectangle = makeOrientedRectangle(center: Coordinate2D(latitude: 41, longitude: -83), lengthMeters: 100,
                                              widthMeters: 60, headingDegrees: 0)
        far.id = UUID()
        XCTAssertTrue(cache.isCurrent(record.id, record: record, fields: [field, far]))
        var widened = field
        widened.rectangle.widthMeters += 5
        XCTAssertFalse(cache.isCurrent(record.id, record: record, fields: [widened]))

        record.notes = "Wet"
        XCTAssertTrue(cache.isCurrent(record.id, record: record, fields: [field]))
        record.trimmedEnd = start.addingTimeInterval(4000)
        XCTAssertFalse(cache.isCurrent(record.id, record: record, fields: [field]))
        XCTAssertFalse(cache.isCurrent(record.id, record: nil, fields: [field]))

        var outdated = cache
        outdated.entries[record.id]?.digest.version = 0
        XCTAssertFalse(outdated.isCurrent(record.id, record: nil, fields: [field]))
    }

    func testOneBadCacheEntryDoesNotCostTheRest() throws {
        let digest = MatchDigest(id: UUID(), startDate: start, endDate: start, format: .match)
        let data = try JSONEncoder().encode(DigestCache(entries: [digest.id: .init(digest: digest, record: nil, center: nil, fields: [])]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object[UUID().uuidString] = ["digest": "nonsense"]
        let decoded = try JSONDecoder().decode(DigestCache.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(Array(decoded.entries.keys), [digest.id])
    }

    // MARK: - Season

    private func digest(daysAgo: Double, effort: Double, minutes: Double = 90) -> MatchDigest {
        let date = start.addingTimeInterval(-daysAgo * 86_400)
        var digest = MatchDigest(id: UUID(), startDate: date, endDate: date.addingTimeInterval(minutes * 60), format: .match)
        digest.effort = effort
        return digest
    }

    func testLoadRatioComparesAWeekWithTheUsualWeek() throws {
        let weekly = [1, 8, 15, 22, 29].map { digest(daysAgo: $0, effort: 50) }
        XCTAssertEqual(try XCTUnwrap(SeasonSummary(weekly).loadRatio(asOf: start)), 1, accuracy: 0.001)
        let heavy = weekly + [digest(daysAgo: 2, effort: 50)]
        XCTAssertEqual(try XCTUnwrap(SeasonSummary(heavy).loadRatio(asOf: start)), 1.6, accuracy: 0.001)
    }

    func testLoadRatioNeedsAMonthToCompareWith() {
        XCTAssertNil(SeasonSummary([1, 3, 5, 9].map { digest(daysAgo: $0, effort: 50) }).loadRatio(asOf: start))
        XCTAssertNil(SeasonSummary([1, 8, 40].map { digest(daysAgo: $0, effort: 50) }).loadRatio(asOf: start))
    }

    func testAverageEffortIsWindowedAndExcludes() {
        let mine = digest(daysAgo: 1, effort: 90)
        let season = SeasonSummary([mine, digest(daysAgo: 10, effort: 40), digest(daysAgo: 20, effort: 60), digest(daysAgo: 40, effort: 0)])
        XCTAssertEqual(season.averageEffort(days: 28, asOf: start, excluding: mine.id), 50)
    }
}
