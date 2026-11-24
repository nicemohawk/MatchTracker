import XCTest
import CoreGraphics
@testable import MatchTrackerKit

/// Tests for geometry-first automatic substitution detection. A synthetic 105×68 pitch and its
/// projector back every case; points are placed in normalized field space and mapped to world
/// coordinates (the exact inverse of `FieldProjector.normalizedPoint`).
/// Repeatable randomness.
private struct Jitter: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state ^ (state >> 29)
    }
}

final class AutoSubDetectorTests: XCTestCase {

    private let fieldCenter = Coordinate2D(latitude: 40.0, longitude: -83.0)
    private lazy var rect = makeOrientedRectangle(center: fieldCenter, lengthMeters: 105, widthMeters: 68, headingDegrees: 0)
    private lazy var projector = FieldProjector(rectangle: rect)

    private let epoch = Date(timeIntervalSince1970: 0)

    /// Place a normalized field point back into world coordinates.
    private func place(x: Double, y: Double) -> Coordinate2D {
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

    /// A coordinate `meters` beyond the near sideline (crossing the short-axis touchline).
    private func outside(meters: Double) -> Coordinate2D {
        place(x: 0.5, y: 1.0 + meters / rect.widthMeters)
    }

    /// A track point at time `t` (seconds from epoch).
    private func point(_ coordinate: Coordinate2D, t: Double, accuracy: Double = 5) -> TrackPoint {
        TrackPoint(coordinate: coordinate, timestamp: epoch.addingTimeInterval(t),
                   speedMetersPerSecond: -1, courseDegrees: -1, horizontalAccuracy: accuracy)
    }

    // MARK: - A match as it's really played

    /// A stretch of somebody's match. Nobody sits still on a bench or runs all the time on a pitch.
    private enum Stretch {
        case playing, bench, winger, keeper, resting, fetchingBall, warmingUp
    }

    private func match(_ stretches: [(minutes: Double, Stretch)], heart: Bool = true)
    -> (track: [TrackPoint], heartRate: [HeartRateSample], starts: [Double]) {
        var generator = Jitter(state: 7)
        var track: [TrackPoint] = [], rates: [HeartRateSample] = [], starts: [Double] = []
        var t = 0.0, rate = 150.0
        var x = 0.5, y = 0.5
        for (minutes, stretch) in stretches {
            starts.append(t)
            switch stretch {
            case .bench, .resting, .fetchingBall, .warmingUp: break
            default: (x, y) = (0.5, 0.5)
            }
            for second in 0..<Int(minutes * 60) {
                var speed = 0.0, target = 160.0
                switch stretch {
                case .playing:
                    speed = second % 50 < 8 ? 3.5 : second % 50 < 35 ? 1.1 : 0.3
                    x = 0.5 + 0.3 * sin(t / 60); y = 0.5 + 0.2 * cos(t / 45)
                case .winger:
                    speed = second % 60 < 9 ? 4 : 1.2
                    x = 0.5 + 0.35 * sin(t / 50); y = 0.97
                case .keeper:
                    speed = second % 170 < 5 ? 2.8 : second % 20 < 8 ? 0.9 : 0.1
                    x = 0.03; y = 0.5 + 0.05 * sin(t / 30); target = 125
                case .resting:    // play is at the other end
                    speed = second % 40 < 15 ? 0.8 : 0.1; target = 150
                case .fetchingBall:
                    speed = 1.5; y = 1.12
                case .bench:      // just inside the line, pacing a third of the time
                    speed = second % 90 < 30 ? 1 : 0.1; target = 112
                    x = 0.5 + 0.02 * sin(t / 20); y = 0.955
                case .warmingUp:  // jogging up and down the line
                    speed = second % 30 < 12 ? 2.8 : 1; target = 130
                    x = 0.5 + 0.2 * sin(t / 25); y = 1.03
                }
                rate += (target - rate) * 0.015
                x += Double.random(in: -0.004...0.004, using: &generator)
                y += Double.random(in: -0.004...0.004, using: &generator)
                var sample = point(place(x: x, y: y), t: t)
                sample.speedMetersPerSecond = speed
                track.append(sample)
                if heart, second.isMultiple(of: 5) {
                    rates.append(HeartRateSample(date: epoch.addingTimeInterval(t), bpm: rate))
                }
                t += 1
            }
        }
        return (track, rates, starts)
    }

    private func subs(_ stretches: [(minutes: Double, Stretch)], heart: Bool = true, existing: [MatchEvent] = [])
    -> [(kind: MatchEventKind, minute: Double)] {
        let match = match(stretches, heart: heart)
        return AutoSubDetector.transitions(track: match.track, projector: projector, existingEvents: existing,
                                           heartRate: match.heartRate)
            .map { ($0.kind, $0.date.timeIntervalSince(epoch) / 60) }
    }

    func testABenchSpellJustInsideTheLine() throws {
        let found = subs([(20, .playing), (9, .bench), (15, .playing)])
        XCTAssertEqual(found.map(\.kind), [.subOut, .subIn])
        XCTAssertEqual(try XCTUnwrap(found.first).minute, 20, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(found.last).minute, 29, accuracy: 1)
    }

    func testABenchSpellWithoutAHeartRate() {
        XCTAssertEqual(subs([(20, .playing), (9, .bench), (15, .playing)], heart: false).map(\.kind), [.subOut, .subIn])
    }

    func testComingOffForGood() {
        XCTAssertEqual(subs([(30, .playing), (25, .bench)]).map(\.kind), [.subOut])
    }

    func testPlayingNeverLooksLikeTheBench() {
        XCTAssertTrue(subs([(45, .playing)]).isEmpty)
        XCTAssertTrue(subs([(45, .winger)]).isEmpty, "hugging the line isn't leaving")
        XCTAssertTrue(subs([(45, .keeper)]).isEmpty, "a goalkeeper stands about for a living")
        XCTAssertTrue(subs([(45, .keeper)], heart: false).isEmpty)
        XCTAssertTrue(subs([(10, .playing), (3, .resting), (10, .playing), (3, .resting), (10, .playing)]).isEmpty,
                      "waiting for play to come back")
        XCTAssertTrue(subs([(10, .playing), (0.7, .fetchingBall), (10, .playing)]).isEmpty)
    }

    func testWarmingUpComesBeforeComingOn() throws {
        let found = subs([(20, .playing), (9, .bench), (2, .warmingUp), (1, .bench), (15, .playing)])
        XCTAssertEqual(found.map(\.kind), [.subOut, .subIn])
        XCTAssertEqual(try XCTUnwrap(found.last).minute, 31, accuracy: 2.5)
    }

    func testTwoSpells() {
        let found = subs([(15, .playing), (7, .bench), (12, .playing), (8, .bench), (10, .playing)])
        XCTAssertEqual(found.map(\.kind), [.subOut, .subIn, .subOut, .subIn])
        XCTAssertEqual(found.map(\.minute), found.map(\.minute).sorted())
    }

    func testManualEventsWin() {
        let wrong = MatchEvent(kind: .subIn, date: epoch.addingTimeInterval(21 * 60))
        XCTAssertFalse(subs([(20, .playing), (6, .bench), (15, .playing)], existing: [
            MatchEvent(kind: .subOut, date: epoch.addingTimeInterval(20 * 60)), wrong
        ]).contains { $0.minute < 26 && $0.kind == .subOut })
    }

    /// The wearer says they never came off, and rests a while longer before playing on.
    func testBeingToldItIsWrongLeavesNothingBehind() throws {
        let match = match([(20, .playing), (7, .bench), (40, .playing)])
        let detector = AutoSubDetector(projector: projector)
        var events: [MatchEvent] = [], rateIndex = 0, rejected = false
        for point in match.track {
            var rate: Double?
            while rateIndex < match.heartRate.count, match.heartRate[rateIndex].date <= point.timestamp {
                rate = match.heartRate[rateIndex].bpm
                rateIndex += 1
            }
            guard let event = detector.process(point: point, heartRate: rate) else { continue }
            if event.kind == .subOut, !rejected {
                rejected = true
                detector.recordManualEvent(MatchEvent(kind: .subIn, date: point.timestamp))
            } else {
                events.append(event)
            }
        }
        XCTAssertTrue(rejected)
        XCTAssertTrue(events.isEmpty, "found \(events.map(\.kind))")
    }

    func testMotionIsReadFromTheRightMoment() {
        var trace = MotionTrace(start: epoch)
        for index in 0..<40 { trace.append(index == 20 ? 1 : 0.2, at: epoch.addingTimeInterval(Double(index) * 5 + 2.5)) }
        XCTAssertEqual(trace.level(at: epoch.addingTimeInterval(102.5)), 1)
        XCTAssertEqual(trace.level(at: epoch.addingTimeInterval(107.5)), 0.2)
        XCTAssertNil(trace.level(at: epoch.addingTimeInterval(-3)))
    }

    func testLowAccuracyFixesDoNotTrigger() {
        let match = match([(20, .playing), (9, .bench)])
        let blind = match.track.map { sample -> TrackPoint in
            var sample = sample
            sample.horizontalAccuracy = 60
            return sample
        }
        XCTAssertTrue(AutoSubDetector.transitions(track: blind, projector: projector, existingEvents: []).isEmpty)
    }

    func testHalftimeArrivalAndLeavingAreNotSubs() {
        let match = match([(30, .playing), (10, .bench), (30, .playing), (8, .bench)])
        let events = AutoSubDetector.detectEvents(
            track: match.track, projector: projector, existingEvents: [],
            halftime: DateInterval(start: epoch.addingTimeInterval(30 * 60), duration: 600), heartRate: match.heartRate)
        XCTAssertTrue(events.isEmpty)
    }

    func testTrackMostlyOffThePitchIsOnTheWrongPitch() {
        let elsewhere = match([(40, .playing)]).track.map { sample -> TrackPoint in
            var sample = sample
            sample.coordinate = outside(meters: 80)
            return sample
        }
        XCTAssertTrue(AutoSubDetector.detectEvents(track: elsewhere, projector: projector, existingEvents: []).isEmpty)
    }

    func testMatchEventDecodesMissingSourceAsManual() throws {
        let json = """
        {"id":"11111111-2222-3333-4444-555555555555","kind":"flag","date":"1970-01-01T00:01:00Z"}
        """
        let event = try MatchTrackerJSON.decoder().decode(MatchEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.source, .manual)
        XCTAssertEqual(event.kind, .flag)

        // And a freshly encoded event always carries the key going forward.
        let data = try MatchTrackerJSON.encoder().encode(MatchEvent(kind: .subOut, date: epoch, source: .automatic))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["source"] as? String, "automatic")
    }

    // MARK: - Motion

    func testRunningIsLearnedFromTheWristThatDoesIt() {
        var calibration = MotionCalibration()
        for _ in 0..<30 { calibration.learn(level: 0.3, speed: 1.2) }
        XCTAssertNil(calibration.runningLevel, "walking alone says nothing about running")
        for _ in 0..<15 { calibration.learn(level: 1.1, speed: 3.2) }
        XCTAssertEqual(try XCTUnwrap(calibration.runningLevel), 0.78, accuracy: 0.01)
        XCTAssertFalse(calibration.isRunning(0.5), "clapping and talking")
        XCTAssertTrue(calibration.isRunning(0.9))

        var still = MotionCalibration()
        for _ in 0..<30 { still.learn(level: 0.3, speed: 1.2) }
        for _ in 0..<15 { still.learn(level: 0.35, speed: 3.2) }
        XCTAssertNil(still.runningLevel, "a wrist that looks the same either way can't tell")
    }

    /// GPS loses quick feet; the wrist doesn't.
    func testRunningTheWristSeesKeepsAPlayerOn() {
        let match = match([(20, .playing), (9, .bench), (10, .playing)])
        func subs(benchLevel: Double) -> [MatchEventKind] {
            var trace = MotionTrace(start: epoch)
            for (index, sample) in match.track.enumerated() where index.isMultiple(of: 5) {
                let running = sample.speedMetersPerSecond >= 2.2
                let onBench = (20 * 60..<29 * 60).contains(index)
                trace.append(onBench ? (index % 40 < 10 ? benchLevel : 0.2) : running ? 1.1 : 0.3, at: sample.timestamp)
            }
            return AutoSubDetector.transitions(track: match.track, projector: projector, existingEvents: [],
                                               motion: trace).map(\.kind)
        }
        XCTAssertEqual(subs(benchLevel: 0.4), [.subOut, .subIn], "pacing and clapping is still the bench")
        XCTAssertEqual(subs(benchLevel: 1.2), [])
    }

    func testMotionTraceGapsAreUnknown() throws {
        var trace = MotionTrace(start: epoch)
        trace.append(0.05, at: trace.start)
        trace.append(0.7, at: trace.start.addingTimeInterval(600))
        XCTAssertNil(trace.level(at: trace.start.addingTimeInterval(300)))
        XCTAssertFalse(trace.hasRun(before: trace.start.addingTimeInterval(605), runningLevel: 0.5),
                       "one sample in a minute says nothing")
        XCTAssertEqual(try JSONDecoder().decode(MotionTrace.self, from: JSONEncoder().encode(trace)), trace)
    }
}
