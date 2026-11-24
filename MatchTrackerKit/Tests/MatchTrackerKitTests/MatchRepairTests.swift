import XCTest
@testable import MatchTrackerKit

final class MatchRepairTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ minute: Double) -> Date { start.addingTimeInterval(minute * 60) }

    private func record(_ events: [MatchEvent] = []) -> MatchRecord {
        MatchRecord(id: UUID(), startDate: start, endDate: at(90), fieldID: nil, events: events, teamCode: nil)
    }

    // MARK: - Events

    func testEditingAnEvent() {
        let goal = MatchEvent(kind: .goalForUs, date: at(80), note: "Corner", source: .automatic)
        var record = record([MatchEvent(kind: .matchStart, date: at(0)), MatchEvent(kind: .flag, date: at(40)), goal])
        record.setEvent(goal.id, kind: .goalMine, date: at(20))
        XCTAssertEqual(record.events.map(\.kind), [.matchStart, .goalMine, .flag])
        XCTAssertEqual(record.events[1].note, "Corner")
        XCTAssertEqual(record.events[1].source, .manual)
        record.setEvent(goal.id, note: "")
        XCTAssertNil(record.events[1].note)
        record.setEvent(UUID(), kind: .assist)
        XCTAssertEqual(record.events.count, 3)
    }

    func testRemovingAnEventCanBeUndone() throws {
        let goal = MatchEvent(kind: .goalMine, date: at(20))
        var record = record([MatchEvent(kind: .matchStart, date: at(0)), goal, MatchEvent(kind: .matchEnd, date: at(90))])
        let before = record.events
        record.add(try XCTUnwrap(record.removeEvent(goal.id)))
        XCTAssertEqual(record.events, before)
        XCTAssertNil(record.removeEvent(UUID()))
    }

    // MARK: - Detection

    private let rectangle = makeOrientedRectangle(center: Coordinate2D(latitude: 40, longitude: -83),
                                                  lengthMeters: 100, widthMeters: 60, headingDegrees: 0)

    private func stationaryTrack() -> [TrackPoint] {
        (0..<5400).map { TrackPoint(coordinate: rectangle.center, timestamp: start.addingTimeInterval(Double($0)),
                                    speedMetersPerSecond: 1, courseDegrees: -1, horizontalAccuracy: 5) }
    }

    func testRedetectionReplacesOldAutomaticEventsOnce() {
        let goal = MatchEvent(kind: .goalMine, date: at(20))
        var record = record([
            MatchEvent(kind: .subOut, date: at(5), source: .automatic), MatchEvent(kind: .subIn, date: at(5.4), source: .automatic),
            MatchEvent(kind: .periodEnd, date: at(79), source: .automatic), MatchEvent(kind: .periodStart, date: at(85), source: .automatic),
            goal
        ])
        let halftime = DateInterval(start: at(43), end: at(50))
        record.redetectEvents(track: stationaryTrack(), projector: FieldProjector(rectangle: rectangle), halftime: halftime)
        XCTAssertEqual(record.events.map(\.kind), [.goalMine, .periodEnd, .periodStart])
        XCTAssertEqual(record.events.map(\.date), [at(20), at(43), at(50)])

        // The wearer deletes one; it must not come back.
        record.removeEvent(record.events[1].id)
        record.redetectEvents(track: stationaryTrack(), projector: FieldProjector(rectangle: rectangle), halftime: halftime)
        XCTAssertEqual(record.events.map(\.kind), [.goalMine, .periodStart])
    }

    func testRedetectionNeedsATrackAndLeavesManualEventsAlone() {
        var record = record([MatchEvent(kind: .periodEnd, date: at(41)), MatchEvent(kind: .periodStart, date: at(48))])
        let before = record.events
        record.redetectEvents(track: [], projector: FieldProjector(rectangle: rectangle), halftime: nil)
        XCTAssertNil(record.detection)
        record.redetectEvents(track: stationaryTrack(), projector: FieldProjector(rectangle: rectangle),
                              halftime: DateInterval(start: at(43), end: at(50)))
        XCTAssertEqual(record.events, before)
    }

    func testAResentRecordKeepsThePhonesEdits() {
        let received = record([MatchEvent(kind: .subOut, date: at(5), source: .automatic)])
        var opened = received
        opened.opponent = "Rovers"
        opened.trimmedEnd = at(80)
        XCTAssertEqual(received.keepingEdits(from: opened).opponent, "Rovers")
        XCTAssertEqual(received.keepingEdits(from: opened).trimmedEnd, at(80))
        opened.detection = 1
        opened.events = [MatchEvent(kind: .goalMine, date: at(20))]
        XCTAssertEqual(received.keepingEdits(from: opened).events, opened.events)
    }

    // MARK: - Trim

    func testTrimIsKeptInsideTheRecording() {
        let recorded = DateInterval(start: start, end: at(400))
        var record = record()
        XCTAssertEqual(record.played(within: recorded), recorded)
        record.trimmedStart = at(-5)
        record.trimmedEnd = at(95)
        XCTAssertEqual(record.played(within: recorded), DateInterval(start: start, end: at(95)))
        record.trimmedStart = at(200)
        XCTAssertEqual(record.played(within: recorded), recorded, "a trim that leaves nothing is ignored")
    }

    private func point(_ minute: Double, speed: Double, meters: Double = 0) -> TrackPoint {
        let coordinate = ENUFrame(reference: rectangle.center).unproject(CGPoint(x: 0, y: meters))
        return TrackPoint(coordinate: coordinate, timestamp: at(minute), speedMetersPerSecond: speed, courseDegrees: -1, horizontalAccuracy: 5)
    }

    func testForgottenRecordingSuggestsWherePlayEnded() throws {
        let play = stride(from: 0, to: 90, by: 0.05).map { point($0, speed: 2) }
        let forgotten = play + stride(from: 90, to: 1913, by: 0.1).map { point($0, speed: 0) }
        let recorded = DateInterval(start: start, end: at(1913))
        let end = try XCTUnwrap(TrimAdvisor.suggestedEnd(recorded: recorded, track: forgotten, heartRate: [], field: nil))
        XCTAssertEqual(end.timeIntervalSince(start) / 60, 91, accuracy: 1)

        // Driving home, then pottering about the house, isn't play either.
        let home = play + stride(from: 90, to: 110, by: 0.05).map { point($0, speed: 14, meters: 5000) }
            + stride(from: 110, to: 140, by: 0.05).map { point($0, speed: 1.5, meters: 9000) }
        XCTAssertEqual(try XCTUnwrap(TrimAdvisor.suggestedEnd(recorded: DateInterval(start: start, end: at(140)), track: home,
                                                              heartRate: [], field: rectangle)).timeIntervalSince(start) / 60,
                       91, accuracy: 1)
    }

    func testNormalEndingSuggestsNothing() {
        let track = stride(from: 0, to: 90, by: 0.05).map { point($0, speed: 2) }
        XCTAssertNil(TrimAdvisor.suggestedEnd(recorded: DateInterval(start: start, end: at(105)), track: track, heartRate: [], field: nil))
        XCTAssertNil(TrimAdvisor.suggestedEnd(recorded: DateInterval(start: start, end: at(105)), track: [], heartRate: [], field: nil))
    }

    func testWithoutARouteTheEndOfWorkoutHeartRateDecides() throws {
        let workout = stride(from: 0, to: 60, by: 0.1).map { HeartRateSample(date: at($0), bpm: 140) }
        let everyday = stride(from: 65, to: 400, by: 5).map { HeartRateSample(date: at($0), bpm: 70) }
        let recorded = DateInterval(start: start, end: at(400))
        XCTAssertEqual(try XCTUnwrap(TrimAdvisor.suggestedEnd(recorded: recorded, track: [], heartRate: workout + everyday, field: nil))
            .timeIntervalSince(start) / 60, 61, accuracy: 0.5)
        XCTAssertNil(TrimAdvisor.suggestedEnd(recorded: recorded, track: [], heartRate: everyday, field: nil))
    }

    // MARK: - Duplicates

    private func span(_ from: Double, _ to: Double, _ source: String, hasRecord: Bool = false) -> WorkoutSpan {
        WorkoutSpan(id: UUID(), interval: DateInterval(start: at(from), end: at(to)), sourceIdentifier: source, hasRecord: hasRecord)
    }

    private let ours = WorkoutSpan.ownSourcePrefix + ".watchkitapp"

    func testOursIsKeptOverAnotherSources() {
        let mine = span(0, 90, ours), strava = span(1, 90, "com.strava"), later = span(200, 290, "com.strava")
        XCTAssertEqual(WorkoutSpan.duplicates(among: [strava, mine, later]), [strava.id])
        let longerStrava = span(-10, 100, "com.strava")
        XCTAssertEqual(WorkoutSpan.duplicates(among: [longerStrava, mine]), [longerStrava.id])
    }

    func testTouchingWorkoutsAreNotDuplicates() {
        XCTAssertEqual(WorkoutSpan.duplicates(among: [span(0, 90, ours), span(80, 170, "com.strava")]), [])
        XCTAssertEqual(WorkoutSpan.duplicates(among: [span(0, 45, "com.apple.health.A"), span(0, 45, "com.apple.health.A")]), [])
    }

    func testForgottenRecordingDoesNotSwallowOtherMatches() {
        XCTAssertEqual(WorkoutSpan.duplicates(among: [span(0, 1913, ours), span(1500, 1590, "com.apple.health.B")]), [])
    }

    func testBetweenStrangersTheOneWithARecordThenTheWatch() {
        let oura = span(0, 90, "com.ouraring.oura"), watch = span(2, 90, "com.apple.health.A")
        XCTAssertEqual(WorkoutSpan.duplicates(among: [oura, watch]), [oura.id])
        let claimed = span(0, 90, "com.ouraring.oura", hasRecord: true)
        XCTAssertEqual(WorkoutSpan.duplicates(among: [claimed, watch]), [watch.id])
    }

    // MARK: - Wire

    func testNewRecordFieldsRoundTripAndAreOptional() throws {
        var record = record()
        record.opponent = "Rovers"
        record.notes = "Windy"
        record.trimmedEnd = at(80)
        record.flipsAttack = true
        let decoded = try MatchTrackerJSON.decoder().decode(MatchRecord.self, from: MatchTrackerJSON.encoder().encode(record))
        XCTAssertEqual(decoded.opponent, "Rovers")
        XCTAssertEqual(decoded.notes, "Windy")
        XCTAssertEqual(decoded.trimmedEnd, at(80))
        XCTAssertEqual(decoded.flipsAttack, true)
        XCTAssertNil(decoded.trimmedStart)
    }

    func testLiveUpdateFromAnOlderWatchDecodes() throws {
        let update = LiveMatchUpdate(sequence: 3, timestamp: start, elapsed: 60, distanceMeters: 100, onPitch: true)
        XCTAssertNil(try MatchTrackerJSON.decoder().decode(LiveMatchUpdate.self, from: MatchTrackerJSON.encoder().encode(update)).matchID)
    }

    // MARK: - Live

    private func update(_ id: UUID?, sequence: Int, minute: Double, elapsed: Double) -> LiveMatchUpdate {
        LiveMatchUpdate(matchID: id, sequence: sequence, timestamp: at(minute), elapsed: elapsed * 60, distanceMeters: 0, onPitch: true)
    }

    func testSecondMatchIsNotMistakenForStaleNews() {
        let first = UUID(), second = UUID()
        let end = update(first, sequence: 900, minute: 90, elapsed: 90)
        XCTAssertTrue(update(second, sequence: 1, minute: 200, elapsed: 0).startsNewMatch(after: end))
        XCTAssertFalse(update(first, sequence: 899, minute: 89, elapsed: 89).startsNewMatch(after: end))
        XCTAssertFalse(update(first, sequence: 899, minute: 89, elapsed: 89).follows(end))
        // A straggler from the first match must not take over the second.
        let started = update(second, sequence: 1, minute: 200, elapsed: 0)
        XCTAssertFalse(end.startsNewMatch(after: started))
        XCTAssertFalse(end.follows(started))
        // And from watches that send no id.
        XCTAssertTrue(update(nil, sequence: 1, minute: 200, elapsed: 0).startsNewMatch(after: update(nil, sequence: 900, minute: 90, elapsed: 90)))
    }

    func testLiveSprintsOnlyEverCountUp() {
        var counter = LiveSprintCounter()
        let speeds = [2.0, 6, 6, 2, 6, 6.2, 5, 6, 6, 3, 6, 6, 6.1, 12, 12, 12, 2]
        let points = speeds.enumerated().map { point(Double($0) / 60, speed: $1) }
        var counts: [Int] = []
        for point in points + points { counter.add(point); counts.append(counter.count) }
        XCTAssertEqual(counter.count, 2, "a one-second spike, a brief dip, a car and redelivery add nothing")
        XCTAssertEqual(counts, counts.sorted())
    }
}
