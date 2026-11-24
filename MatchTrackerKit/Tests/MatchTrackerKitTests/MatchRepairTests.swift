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

    func testAScoreGivenOnTheWatchReachesAMatchThePhoneAlreadyHas() {
        var resent = record([MatchEvent(kind: .subOut, date: at(5), source: .automatic)])
        var opened = resent
        resent.finalScore = FinalScore(us: 0, them: 0)
        opened.detection = 1
        opened.opponent = "Rovers"
        XCTAssertEqual(resent.keepingEdits(from: opened).finalScore, FinalScore(us: 0, them: 0))
        XCTAssertEqual(resent.keepingEdits(from: opened).opponent, "Rovers")
        // Whichever copy arrives first, and whatever the phone has been told since.
        XCTAssertEqual(opened.keepingEdits(from: resent).finalScore, FinalScore(us: 0, them: 0))
        opened.finalScore = FinalScore(us: 2, them: 1)
        XCTAssertEqual(resent.keepingEdits(from: opened).finalScore, FinalScore(us: 2, them: 1))
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

    // MARK: - Scores and late records

    func testTheWearersScoreOutranksTheLoggedOne() {
        var record = MatchRecord(id: UUID(), startDate: at(0), endDate: at(90), fieldID: nil,
                                 events: [MatchEvent(kind: .goalForUs, date: at(20))], teamCode: nil)
        XCTAssertEqual(record.score, FinalScore(us: 1, them: 0))
        record.finalScore = FinalScore(us: 3, them: 1, mine: 2)
        let digest = MatchDigest(id: record.id, interval: DateInterval(start: at(0), end: at(90)), format: .match,
                                 record: record, analytics: nil)
        XCTAssertEqual([digest.goalsUs, digest.goalsThem, digest.myGoals], [3, 1, 2])
        for _ in 0..<2 { record.add(MatchEvent(kind: .goalAgainstUs, date: at(30))) }
        XCTAssertEqual(record.score, FinalScore(us: 3, them: 2, mine: 2), "another goal logged is another goal")
    }

    func testGoallessIsAResult() {
        var record = MatchRecord(id: UUID(), startDate: at(0), endDate: at(90), fieldID: nil, events: [], teamCode: nil)
        XCTAssertNil(record.score)
        record.finalScore = FinalScore(us: 0, them: 0)
        XCTAssertEqual(MatchDigest(id: record.id, interval: DateInterval(start: at(0), end: at(90)), format: .match,
                                   record: record, analytics: nil).result, .drawn)
    }

    func testWatchRecordArrivingAfterThePhoneStartedOne() {
        let added = MatchEvent(kind: .assist, date: at(50))
        var started = MatchRecord(id: UUID(), startDate: at(0), endDate: at(90), fieldID: nil, events: [added], teamCode: nil)
        started.startedOnPhone = true
        started.finalScore = FinalScore(us: 2, them: 2)
        started.detection = MatchRecord.currentDetection
        let flag = MatchEvent(kind: .flag, date: at(10))
        let received = MatchRecord(id: started.id, startDate: at(0), endDate: at(91), fieldID: nil,
                                   events: [flag], teamCode: "ABC", format: .indoor)
        let merged = received.keepingEdits(from: started)
        XCTAssertEqual(merged.events.map(\.id), [flag.id, added.id])
        XCTAssertEqual(merged.finalScore, started.finalScore)
        XCTAssertEqual(merged.format, .indoor)
        XCTAssertEqual(merged.teamCode, "ABC")
        XCTAssertNil(merged.startedOnPhone)
        XCTAssertNil(merged.detection, "the watch's events haven't been looked at yet")
    }

    // MARK: - Substitutions the wearer had a say in

    func testAnAutomaticSubOffAndAManualReturnStayAPair() {
        var record = MatchRecord(id: UUID(), startDate: at(0), endDate: at(90), fieldID: nil, events: [
            MatchEvent(kind: .subOut, date: at(20), source: .automatic), MatchEvent(kind: .subIn, date: at(30)),
            MatchEvent(kind: .subOut, date: at(45), source: .automatic), MatchEvent(kind: .subIn, date: at(54), source: .automatic)
        ], teamCode: nil)
        let rectangle = makeOrientedRectangle(center: Coordinate2D(latitude: 40, longitude: -83), lengthMeters: 100,
                                              widthMeters: 60, headingDegrees: 0)
        let track = (0..<(90 * 12)).map {
            TrackPoint(coordinate: rectangle.center, timestamp: at(Double($0) / 12), speedMetersPerSecond: 2,
                       courseDegrees: 0, horizontalAccuracy: 5)
        }
        record.redetectEvents(track: track, projector: FieldProjector(rectangle: rectangle),
                              halftime: DateInterval(start: at(45), end: at(55)))
        XCTAssertEqual(record.events.filter { $0.kind == .subIn || $0.kind == .subOut }.map(\.date), [at(20), at(30)],
                       "half-time isn't a substitution, whoever noticed it")
        let intervals = PlayIntervalDeriver.playingIntervals(track: track, field: rectangle, events: record.events,
                                                             matchStart: at(0), matchEnd: at(90))
        XCTAssertEqual(intervals, [DateInterval(start: at(0), end: at(20)), DateInterval(start: at(30), end: at(90))])
    }

    func testARejectedSubIsNotFoundAgain() {
        var record = MatchRecord(id: UUID(), startDate: at(0), endDate: at(90), fieldID: nil, events: [
            MatchEvent(kind: .subOut, date: at(20), source: .automatic)
        ], teamCode: nil)
        XCTAssertFalse(record.hasSettledSubs)
        record.removeEvent(record.events[0].id)
        XCTAssertTrue(record.hasSettledSubs)
        let input = MatchAnalysisInput(record: record, interval: DateInterval(start: at(0), end: at(90)), format: .match,
                                       track: [], heartRate: [], healthDistanceMeters: nil, savedField: nil)
        XCTAssertTrue(input.hasSettledSubs)
        XCTAssertEqual(record.keepingEdits(from: MatchRecord(id: record.id, startDate: at(0), endDate: nil, fieldID: nil,
                                                             events: [], teamCode: nil)).rejectedSubOuts, 1)
    }

    // MARK: - Coming and going

    private static let pitch = Coordinate2D(latitude: 40, longitude: -83)

    /// Fixes every two seconds: how far from the pitch, and how fast.
    private func journey(_ legs: [(minutes: Double, from: Double, to: Double, speed: Double)]) -> [TrackPoint] {
        var points: [TrackPoint] = [], t = 0.0
        for leg in legs {
            let count = Int(leg.minutes * 30)
            for index in 0..<count {
                let meters = leg.from + (leg.to - leg.from) * Double(index) / Double(count)
                let sway = leg.speed < 7 ? 20 * sin(t / 15) : 0
                points.append(TrackPoint(
                    coordinate: Coordinate2D(latitude: Self.pitch.latitude + sway / 111_320,
                                             longitude: Self.pitch.longitude + meters / (111_320 * cos(40 * .pi / 180))),
                    timestamp: at(t / 60), speedMetersPerSecond: leg.speed, courseDegrees: 0, horizontalAccuracy: 5))
                t += 2
            }
        }
        return points
    }

    func testTheDriveHomeIsLeftOut() throws {
        let track = journey([(60, 0, 0, 2.6), (5, 0, 60, 0.6), (10, 60, 6000, 12)])
        let recorded = DateInterval(start: at(0), end: at(75))
        let played = try XCTUnwrap(TrimAdvisor.atThePitch(recorded: recorded, track: track, field: nil))
        XCTAssertEqual(played.start, at(0))
        XCTAssertEqual(played.end.timeIntervalSince(at(0)) / 60, 61, accuracy: 1.5, "nor the walk to the car")
        XCTAssertTrue(TrimAdvisor.hasLeft(track: track, field: nil))

        var record = MatchRecord(id: UUID(), startDate: at(0), endDate: at(75), fieldID: nil, events: [], teamCode: nil)
        XCTAssertTrue(record.trimJourneys(recorded: recorded, track: track, field: nil))
        XCTAssertEqual(record.trimmedEnd, played.end)
        record.trimmedEnd = nil
        record.keepsWholeRecording = true
        XCTAssertFalse(record.trimJourneys(recorded: recorded, track: track, field: nil), "asked for all of it")
    }

    func testTheDriveThereIsLeftOut() throws {
        let track = journey([(10, 5000, 120, 10), (5, 120, 0, 1.2), (60, 0, 0, 2.6)])
        let played = try XCTUnwrap(TrimAdvisor.atThePitch(recorded: DateInterval(start: at(0), end: at(75)), track: track, field: nil))
        XCTAssertEqual(played.start.timeIntervalSince(at(0)) / 60, 10, accuracy: 1)
        XCTAssertEqual(played.end, at(75))
    }

    func testPlayingIsNeverLeaving() {
        let recorded = DateInterval(start: at(0), end: at(90))
        for track in [journey([(90, 0, 0, 2.6)]),
                      journey([(45, 0, 0, 2.6), (10, 0, 140, 0.8), (35, 0, 0, 2.6)]),      // half-time at the car
                      journey([(45, 0, 0, 2.6), (5, 0, 3000, 12), (5, 3000, 0, 12), (35, 0, 0, 2.6)])] {   // and back
            XCTAssertNil(TrimAdvisor.atThePitch(recorded: recorded, track: track, field: nil))
            XCTAssertFalse(TrimAdvisor.hasLeft(track: track, field: nil))
        }
    }
}
