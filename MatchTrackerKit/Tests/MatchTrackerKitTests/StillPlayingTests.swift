import XCTest
@testable import MatchTrackerKit

final class StillPlayingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ minute: Double) -> Date { start.addingTimeInterval(minute * 60) }

    private struct Heard {
        var asked: [(minute: Double, question: StillPlaying.Question)] = []
        var withdrawn: [Double] = []
        var ended: (minute: Double, question: StillPlaying.Question)?
    }

    /// Plays a whole recording through, asking every half minute as the watch does.
    private func follow(track: [TrackPoint] = [], heartRate: [HeartRateSample] = [], minutes: Double, format: MatchFormat = .match,
                        field: OrientedRectangle? = nil, lastRun: ((Date) -> Date?)? = nil, canSeeRuns: Bool = true,
                        answerAt: Double? = nil, watch: inout StillPlaying) -> Heard {
        var heard = Heard()
        for half in 1...Int(minutes * 2) {
            let minute = Double(half) / 2, now = at(minute)
            let seen = Array(track.prefix { $0.timestamp <= now })
            let action = watch.consider(StillPlaying.Evidence(
                now: now, start: start, format: format, track: seen, field: field,
                heartRate: Array(heartRate.prefix { $0.date <= now }),
                lastRun: lastRun?(now) ?? seen.last { (1.8..<7).contains($0.speedMetersPerSecond) }?.timestamp,
                canSeeRuns: canSeeRuns))
            switch action {
            case .none: break
            case .ask(let question): heard.asked.append((minute, question))
            case .withdraw: heard.withdrawn.append(minute)
            case .end(let question, _):
                heard.ended = (minute, question)
                return heard
            }
            if let answerAt, minute >= answerAt, watch.question != nil { watch.answerStillPlaying(at: now) }
        }
        return heard
    }

    // MARK: Outdoors

    private static let pitch = Coordinate2D(latitude: 40, longitude: -83)
    private typealias Leg = (minutes: Double, from: Double, to: Double, speed: Double)

    /// A fix a second: how far from the pitch, and how fast.
    private func journey(_ legs: [Leg]) -> [TrackPoint] {
        var points: [TrackPoint] = [], t = 0.0
        for leg in legs {
            let count = Int(leg.minutes * 60)
            for index in 0..<count {
                let meters = leg.from + (leg.to - leg.from) * Double(index) / Double(count)
                let sway = leg.speed < 7 ? 20 * sin(t / 15) : 0
                points.append(TrackPoint(
                    coordinate: Coordinate2D(latitude: Self.pitch.latitude + sway / 111_320,
                                             longitude: Self.pitch.longitude + meters / (111_320 * cos(40 * .pi / 180))),
                    timestamp: start.addingTimeInterval(t), speedMetersPerSecond: leg.speed, courseDegrees: 0,
                    horizontalAccuracy: 5))
                t += 1
            }
        }
        return points
    }

    private func follow(_ legs: [Leg], answerAt: Double? = nil) -> (heard: Heard, watch: StillPlaying) {
        var watch = StillPlaying(watchingSince: start)
        let track = journey(legs)
        let heard = follow(track: track, minutes: Double(track.count) / 60, answerAt: answerAt, watch: &watch)
        return (heard, watch)
    }

    func testDrivingOffIsAskedAboutAtOnceAndThenEnds() throws {
        let heard = follow([(60, 0, 0, 2.6), (5, 0, 60, 0.6), (40, 60, 28_000, 12)]).heard
        let first = try XCTUnwrap(heard.asked.first)
        XCTAssertEqual(first.question.reason, .left)
        XCTAssertEqual(first.minute, 66.5, accuracy: 1.5)
        XCTAssertEqual(first.question.end.timeIntervalSince(start) / 60, 61, accuracy: 1.5, "when play ended, not when the car left")
        XCTAssertEqual(heard.asked.map { ($0.minute - first.minute).rounded() }, [0, 5], "asked again while it goes unanswered")
        let ended = try XCTUnwrap(heard.ended)
        XCTAssertEqual(ended.minute - first.minute, 10.5, accuracy: 2)
        XCTAssertEqual(ended.question.end.timeIntervalSince(start) / 60, 61, accuracy: 1.5)
    }

    func testDrivingAwayAndBackAsksOnceAndLosesNothing() {
        let legs: [Leg] = [(45, 0, 0, 2.6), (4, 0, 2880, 12), (4, 2880, 0, 12), (2, 0, 0, 2.6),
                           (3, 0, 2160, 12), (3, 2160, 0, 12), (25, 0, 0, 2.6)]
        let (heard, watch) = follow(legs)
        XCTAssertEqual(Set(heard.asked.map(\.question.asked)).count, 1, "and not again for the second trip, minutes later")
        XCTAssertEqual(heard.withdrawn.count, 1)
        XCTAssertNil(heard.ended)
        let track = journey(legs)
        XCTAssertNil(watch.endBeforeLeaving(recorded: DateInterval(start: start, end: at(86)), track: track, field: nil))
    }

    func testEndingByHandAfterTheDriveLeavesItOut() throws {
        let legs: [Leg] = [(60, 0, 0, 2.6), (10, 0, 7200, 12)]
        let track = journey(legs)
        let recorded = DateInterval(start: start, end: at(70))
        let watch = StillPlaying(watchingSince: start)
        XCTAssertEqual(try XCTUnwrap(watch.endBeforeLeaving(recorded: recorded, track: track, field: nil))
            .timeIntervalSince(start) / 60, 60, accuracy: 1.5)

        let denied = follow(legs, answerAt: 62)
        XCTAssertEqual(denied.heard.asked.count, 1)
        XCTAssertNil(denied.watch.endBeforeLeaving(recorded: recorded, track: track, field: nil), "said they hadn't left")
    }

    func testNothingIsCutFromAMatch() {
        let watch = StillPlaying(watchingSince: start)
        // Sitting out the end, with a few wild fixes to finish.
        var wild = journey([(50, 0, 0, 2.6), (15, 10, 20, 0.3)])
        wild += journey([(0.2, 900, 900, 0)]).map {
            TrackPoint(coordinate: $0.coordinate, timestamp: $0.timestamp.addingTimeInterval(65 * 60),
                       speedMetersPerSecond: 0, courseDegrees: 0, horizontalAccuracy: 45)
        }
        let secondPitch = journey([(40, 0, 0, 2.6), (8, 0, 700, 1.4), (20, 700, 700, 2.6)])
        for track in [wild, secondPitch, journey([(90, 0, 0, 2.6)]), journey([(60, 0, 0, 2.6), (5, 0, 350, 1.3)])] {
            let recorded = DateInterval(start: start, end: track.last!.timestamp)
            XCTAssertNil(watch.endBeforeLeaving(recorded: recorded, track: track, field: nil))
        }
    }

    func testAnOrdinaryMatchIsNeverAskedAbout() {
        // With a fifteen-minute half-time, and fifteen minutes on the bench.
        let heard = follow([(45, 0, 0, 2.6), (15, 0, 140, 0.3), (20, 0, 0, 2.6), (15, 20, 25, 0.5), (10, 0, 0, 2.6)]).heard
        XCTAssertTrue(heard.asked.isEmpty)
    }

    func testNotRunningIsNotNotPlaying() {
        let field = makeOrientedRectangle(center: Self.pitch, lengthMeters: 100, widthMeters: 60, headingDegrees: 0)
        // Standing in goal all half; walking football; and standing about with a heart that's never at rest.
        var watch = StillPlaying(watchingSince: start)
        XCTAssertTrue(follow(track: journey([(10, 0, 0, 2.6), (80, 0, 0, 0.2)]), minutes: 90, field: field, watch: &watch).asked.isEmpty)
        watch = StillPlaying(watchingSince: start)
        XCTAssertTrue(follow(track: journey([(90, 0, 0, 1.2)]), minutes: 90, watch: &watch).asked.isEmpty)
        watch = StillPlaying(watchingSince: start)
        XCTAssertTrue(follow(track: journey([(10, 0, 0, 2.6), (80, 0, 0, 0.2)]), heartRate: heart([(10, 140), (40, 128), (40, 116)]),
                             minutes: 90, watch: &watch).asked.isEmpty)
    }

    func testALongSitOutInATournament() {
        var watch = StillPlaying(watchingSince: start)
        let legs: [Leg] = [(20, 0, 0, 2.6), (25, 0, 40, 0.3), (20, 0, 0, 2.6), (25, 0, 40, 0.3), (20, 0, 0, 2.6)]
        XCTAssertTrue(follow(track: journey(legs), minutes: 110, format: .smallSided, watch: &watch).asked.isEmpty)
    }

    func testStillnessIsAskedAboutAndEndsOnlyAfterHoursOfIt() throws {
        var watch = StillPlaying(watchingSince: start)
        let track = journey([(60, 0, 0, 2.6), (130, 10, 12, 0.1)])
        let heard = follow(track: track, minutes: 190, watch: &watch)
        XCTAssertEqual(try XCTUnwrap(heard.asked.first).minute, 80.5, accuracy: 1)
        XCTAssertEqual(heard.asked.count, 4, "four buzzes and then quiet")
        XCTAssertEqual(try XCTUnwrap(heard.ended).minute, 150, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(heard.ended).question.end.timeIntervalSince(start) / 60, 60, accuracy: 1.5)
    }

    func testNoGPSIsNotStillness() {
        var watch = StillPlaying(watchingSince: start)
        XCTAssertTrue(follow(minutes: 120, canSeeRuns: false, watch: &watch).asked.isEmpty)
    }

    // MARK: Indoors

    private typealias Stretch = (minutes: Double, rate: Double)

    /// A heart that takes most of a minute to answer, sampled like a watch does.
    private func heart(_ stretches: [Stretch]) -> [HeartRateSample] {
        var samples: [HeartRateSample] = [], rate = 100.0, t = 0.0
        for stretch in stretches {
            for _ in 0..<Int(stretch.minutes * 60) {
                let target = stretch.rate > 130 ? stretch.rate + 8 * sin(t / 20) : stretch.rate
                rate += (target - rate) / (target > rate ? 40 : 70)
                if t.truncatingRemainder(dividingBy: 5) == 0 {
                    samples.append(HeartRateSample(date: start.addingTimeInterval(t), bpm: rate))
                }
                t += 1
            }
        }
        return samples
    }

    /// Three games with long sit-outs and rolling subs, as an indoor night goes.
    private let booking: [Stretch] = [(6, 108), (9, 160), (3, 112), (8, 162), (21, 100), (8, 158), (2, 115), (10, 161),
                                      (15, 101), (12, 160)]
    private var bookingMinutes: Double { booking.reduce(0) { $0 + $1.minutes } }

    private func indoor(_ stretches: [Stretch], seesRuns: Bool, answerAt: Double? = nil) -> Heard {
        var watch = StillPlaying(watchingSince: start)
        var played: [(from: Double, to: Double)] = [], t = 0.0
        for stretch in stretches {
            if stretch.rate > 130 { played.append((t, t + stretch.minutes)) }
            t += stretch.minutes
        }
        return follow(heartRate: heart(stretches), minutes: t, format: .indoor, lastRun: { now in
            let minute = now.timeIntervalSince(self.start) / 60
            return seesRuns ? played.last { $0.from <= minute }.map { self.at(min($0.to, minute)) } : nil
        }, canSeeRuns: seesRuns, answerAt: answerAt, watch: &watch)
    }

    func testSitOutsBetweenGamesAreNeverTheEnd() {
        for seesRuns in [true, false] {
            XCTAssertTrue(indoor(booking, seesRuns: seesRuns).asked.isEmpty)
        }
        // One long steady game, then a long sit-out: nothing climbs in either.
        XCTAssertTrue(indoor([(5, 108), (40, 160), (25, 98), (20, 160)], seesRuns: false).asked.isEmpty)
        // A goalkeeper: busy, then standing for the whole second half, and never running.
        XCTAssertTrue(indoor([(40, 128), (15, 112), (40, 114)], seesRuns: false).asked.isEmpty)
        // Walking football: flat all the way, with a break.
        XCTAssertTrue(indoor([(30, 112), (15, 98), (30, 112), (15, 98), (30, 112)], seesRuns: false).asked.isEmpty)
    }

    func testForgottenIndoors() throws {
        for seesRuns in [true, false] {
            let heard = indoor(booking + [(120, 82)], seesRuns: seesRuns)
            let first = try XCTUnwrap(heard.asked.first, "runs seen: \(seesRuns)")
            XCTAssertEqual(first.question.reason, .noPlay)
            XCTAssertEqual(first.minute - bookingMinutes, seesRuns ? 35 : 30, accuracy: 3)
            XCTAssertEqual(first.question.end.timeIntervalSince(start) / 60, bookingMinutes + 1, accuracy: 2.5)
            XCTAssertEqual(heard.asked.count, 4)
            let ended = try XCTUnwrap(heard.ended)
            XCTAssertEqual(ended.minute - bookingMinutes, 91, accuracy: 3)
            XCTAssertEqual(ended.question.end.timeIntervalSince(start) / 60, bookingMinutes + 1, accuracy: 2.5)
        }
    }

    func testRelaunchedAtHomeLongAfter() throws {
        var watch = StillPlaying(watchingSince: start)
        let heartRate = heart(booking + [(70, 82)])
        let now = at(bookingMinutes + 70)
        guard case .ask(let question) = watch.consider(StillPlaying.Evidence(
            now: now, start: start, format: .indoor, heartRate: heartRate, canSeeRuns: false)) else { return XCTFail() }
        XCTAssertEqual(question.end.timeIntervalSince(start) / 60, bookingMinutes + 2, accuracy: 3)
    }

    func testStillPlayingIsBelievedForTwentyMinutes() {
        let heard = indoor(booking + [(100, 82)], seesRuns: true, answerAt: bookingMinutes)
        let minutes = heard.asked.map(\.minute)
        XCTAssertGreaterThan(minutes.count, 1)
        for (first, second) in zip(minutes, minutes.dropFirst()) { XCTAssertGreaterThanOrEqual(second - first, 20) }
        XCTAssertNil(heard.ended, "answered is not unanswered")
    }

    func testALongSessionIsAskedAboutButPlayIsNeverEnded() throws {
        let heard = indoor(Array(repeating: [(8, 160), (4, 112)], count: 17).flatMap { $0 }, seesRuns: true)
        let first = try XCTUnwrap(heard.asked.first)
        XCTAssertEqual(first.minute, 150.5, accuracy: 0.6)
        XCTAssertEqual(first.question.reason, .longSession)
        XCTAssertEqual(first.question.end, first.question.asked)
        XCTAssertNil(heard.ended)
    }

    func testLookingIsCheap() {
        let evidence = StillPlaying.Evidence(now: at(120), start: start, format: .match,
                                             track: journey([(110, 0, 0, 2.6), (10, 0, 7200, 12)]),
                                             heartRate: heart(booking), lastRun: at(110), canSeeRuns: true)
        measure {
            var watch = StillPlaying(watchingSince: start)
            _ = watch.consider(evidence)
        }
    }
}
