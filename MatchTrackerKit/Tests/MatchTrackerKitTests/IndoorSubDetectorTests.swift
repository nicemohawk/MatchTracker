import XCTest
@testable import MatchTrackerKit

final class IndoorSubDetectorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Jitter: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state ^ (state >> 29)
        }
    }

    /// Plays out a session. A bench isn't still: people pace, clap and drink. Play isn't constant.
    private func play(_ stretches: [(minutes: Double, isOn: Bool)], with detector: IndoorSubDetector,
                      high: Double = 160, low: Double = 112, wrist: Bool = true) -> [(kind: MatchEventKind, minute: Double, noticed: Double)] {
        var generator = Jitter(state: 5), rate = low, t = 0.0
        var found: [(MatchEventKind, Double, Double)] = []
        for stretch in stretches {
            for second in 0..<Int(stretch.minutes * 60) {
                let target = (stretch.isOn ? high + 7 * sin(t / 22) : low) + Double.random(in: -3...3, using: &generator)
                rate += (target - rate) / (target > rate ? 40 : 70)
                t += 1
                guard t.truncatingRemainder(dividingBy: 5) == 0 else { continue }
                let pacing = second % 60 < 25
                let level = stretch.isOn ? (second % 30 < 12 ? 1.0 : 0.4) : (pacing ? 0.3 : 0.08)
                if let event = detector.process(at: start.addingTimeInterval(t), heartRate: rate,
                                                motion: wrist ? level * Double.random(in: 0.8...1.2, using: &generator) : nil) {
                    found.append((event.kind, event.date.timeIntervalSince(start) / 60, t / 60))
                }
            }
        }
        return found
    }

    func testRollingSubsFromTheHeartAlone() {
        let found = play([(10, true), (4, false), (8, true), (5, false), (9, true)], with: IndoorSubDetector(), wrist: false)
        XCTAssertEqual(found.map(\.kind), [.subOut, .subIn, .subOut, .subIn])
        for (event, minute) in zip(found, [10.0, 14, 22, 27]) {
            XCTAssertEqual(event.minute, minute, accuracy: 1.2)
            XCTAssertLessThan(event.noticed - minute, 2.2)
        }
    }

    func testTheWristSpeaksFirstOnceItsKnown() {
        let detector = IndoorSubDetector()
        _ = play([(10, true), (6, false), (10, true), (6, false), (8, true)], with: detector)
        XCTAssertTrue(detector.motion.canTell)
        let quick = play([(9, true), (4, false), (8, true)], with: IndoorSubDetector(motion: detector.motion))
        XCTAssertEqual(quick.map(\.kind), [.subOut, .subIn])
        let slow = play([(9, true), (4, false), (8, true)], with: IndoorSubDetector(), wrist: false)
        XCTAssertLessThan(quick[0].noticed, slow[0].noticed - 0.4)
        XCTAssertLessThan(quick[0].noticed - 9, 1.1)
    }

    func testABreatherIsNotARest() {
        XCTAssertTrue(play([(10, true), (0.6, false), (8, true), (0.7, false), (8, true)], with: IndoorSubDetector()).isEmpty)
    }

    func testAGoalkeepersNightHoldsNoSubs() {
        // Busy spells and quiet ones, but always on.
        XCTAssertTrue(play([(12, true), (6, false), (12, true), (8, false), (12, true)], with: IndoorSubDetector(),
                           high: 122, low: 106, wrist: false).isEmpty)
    }

    func testPlayingThroughout() {
        XCTAssertTrue(play([(50, true)], with: IndoorSubDetector()).isEmpty)
    }

    func testARestlessBenchDoesntConfuseTheHeart() {
        // A wrist as lively off as on teaches nothing, so the heart keeps deciding.
        let detector = IndoorSubDetector()
        var generator = Jitter(state: 9), rate = 112.0, t = 0.0
        var kinds: [MatchEventKind] = []
        for (minutes, isOn) in [(10.0, true), (6.0, false), (10.0, true)] {
            for _ in 0..<Int(minutes * 60) {
                rate += ((isOn ? 160 : 112) - rate) / (isOn ? 40 : 70)
                t += 1
                guard t.truncatingRemainder(dividingBy: 5) == 0 else { continue }
                if let event = detector.process(at: start.addingTimeInterval(t), heartRate: rate,
                                                motion: Double.random(in: 0.2...1, using: &generator)) { kinds.append(event.kind) }
            }
        }
        XCTAssertFalse(detector.motion.canTell)
        XCTAssertEqual(kinds, [.subOut, .subIn])
    }

    func testTheWearerHasTheLastWord() {
        let detector = IndoorSubDetector()
        _ = play([(10, true)], with: detector, wrist: false)
        detector.reject(at: start.addingTimeInterval(600))
        var kinds: [MatchEventKind] = []
        var rate = 158.0
        for second in stride(from: 605.0, to: 880, by: 5) {
            rate += (112 - rate) / 12
            if let event = detector.process(at: start.addingTimeInterval(second), heartRate: rate, motion: nil) { kinds.append(event.kind) }
        }
        XCTAssertTrue(kinds.isEmpty)
    }

    func testAMissingHeartRateChangesNothing() {
        let detector = IndoorSubDetector()
        _ = play([(10, true)], with: detector, wrist: false)
        for second in stride(from: 605.0, to: 1200, by: 5) {
            XCTAssertNil(detector.process(at: start.addingTimeInterval(second), heartRate: nil, motion: 0.05))
        }
    }

    func testMotionSurvivesBeingSaved() throws {
        let detector = IndoorSubDetector()
        _ = play([(10, true), (6, false), (10, true), (6, false)], with: detector)
        let saved = try JSONDecoder().decode(IndoorMotion.self, from: JSONEncoder().encode(detector.motion))
        XCTAssertEqual(saved, detector.motion)
        XCTAssertTrue(saved.canTell)
    }
}
