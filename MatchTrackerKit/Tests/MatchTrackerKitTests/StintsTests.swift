import XCTest
@testable import MatchTrackerKit

final class StintsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A heart that takes most of a minute to answer, sampled like a watch does.
    private func heart(_ stretches: [(minutes: Double, isOn: Bool)], every seconds: Double = 5) -> ([HeartRateSample], DateInterval) {
        var samples: [HeartRateSample] = [], rate = 105.0, t = 0.0
        for stretch in stretches {
            for _ in 0..<Int(stretch.minutes * 60) {
                // Play isn't steady: it swings a little every half minute.
                let target = stretch.isOn ? 160 + 8 * sin(t / 20) : 108
                rate += (target - rate) / (target > rate ? 40 : 70)
                if t.truncatingRemainder(dividingBy: seconds) == 0 {
                    samples.append(HeartRateSample(date: start.addingTimeInterval(t), bpm: rate))
                }
                t += 1
            }
        }
        return (samples, DateInterval(start: start, duration: t))
    }

    private func stints(_ stretches: [(Double, Bool)], every seconds: Double = 5) -> Stints? {
        let (samples, interval) = heart(stretches, every: seconds)
        return Stints.detect(heartRate: samples, in: interval)
    }

    func testRollingSubs() throws {
        let found = try XCTUnwrap(stints([(2, false), (8, true), (3, false), (6, true), (4, false), (10, true), (2, false)]))
        XCTAssertEqual(found.playing.count, 3)
        let minutes = found.playing.map { $0.start.timeIntervalSince(start) / 60 }
        for (minute, expected) in zip(minutes, [2, 13, 23]) { XCTAssertEqual(minute, Double(expected), accuracy: 0.7) }
        XCTAssertEqual(found.played / 60, 24, accuracy: 1.5)
        XCTAssertEqual(found.longest / 60, 10, accuracy: 1)
        XCTAssertEqual(found.games.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(found.recovery), 20)
    }

    func testOneBookingThreeGames() throws {
        let found = try XCTUnwrap(stints([(5, false), (10, true), (2, false), (9, true), (17, false), (22, true), (15, false), (20, true)]))
        XCTAssertEqual(found.games.map(\.count), [2, 1, 1])
    }

    func testAThrowInIsNotAChange() throws {
        XCTAssertEqual(try XCTUnwrap(stints([(4, false), (8, true), (0.6, false), (8, true), (5, false)])).playing.count, 1)
    }

    func testPlayingThroughoutIsNotGuessedAt() {
        XCTAssertNil(stints([(60, true)].map { ($0.0, $0.1) }).flatMap { $0.playing.count > 1 ? $0 : nil })
    }

    func testTooSparseToFollow() {
        XCTAssertNil(stints([(5, false), (10, true), (10, false), (10, true)], every: 60))
    }

    func testStripShowsOnAndOff() throws {
        let strip = try XCTUnwrap(stints([(12, true), (12, false), (12, true), (12, false)])).strip
        XCTAssertEqual(strip.count, Stints.stripCount)
        XCTAssertGreaterThan(strip[6], 0.3)
        XCTAssertEqual(strip[18], 0)
        XCTAssertGreaterThan(strip[30], 0.3)
    }

    func testMinutesPlayedIndoorsAreTheStints() throws {
        let (samples, interval) = heart([(3, false), (15, true), (15, false), (15, true), (5, false)])
        let analytics = try XCTUnwrap(MatchAnalyzer.analyze(MatchAnalysisInput(
            interval: interval, format: .indoor, heartRate: samples, healthDistanceMeters: 3000)))
        XCTAssertEqual(analytics.workrate.timeOnPitch / 60, 30, accuracy: 2)
        let digest = MatchDigest(id: UUID(), interval: interval, format: .indoor, record: nil, analytics: analytics)
        XCTAssertEqual(digest.stintCount, 2)
        XCTAssertEqual(digest.distanceMeters, 3000)
        XCTAssertNotNil(digest.strip)
    }

    func testSubsTheWearerLoggedCountToo() throws {
        let (samples, interval) = heart([(3, false), (15, true), (15, false), (15, true), (5, false)])
        let analytics = try XCTUnwrap(MatchAnalyzer.analyze(MatchAnalysisInput(
            interval: interval, format: .indoor,
            events: [MatchEvent(kind: .subOut, date: start.addingTimeInterval(40 * 60))], heartRate: samples)))
        XCTAssertEqual(analytics.workrate.timeOnPitch / 60, 22, accuracy: 2)
    }

    // MARK: - Games

    /// Blocks of one or two twelve-minute games, with long sit-outs between.
    func testShortGamesInBlocks() throws {
        let found = try XCTUnwrap(stints([(5, false), (11, true), (2, false), (11, true), (17, false), (24, true), (15, false), (13, true)]))
        let interval = DateInterval(start: start, duration: 98 * 60)
        let games = Games.inSession(record: nil, stints: found, interval: interval, length: 12 * 60)
        XCTAssertEqual(games.count, 5)
        XCTAssertTrue(games.allSatisfy { (8 * 60...16 * 60).contains($0.end.timeIntervalSince($0.start)) })
        XCTAssertEqual(zip(games, games.dropFirst()).filter { $0.end > $1.start.addingTimeInterval(1) }.count, 0)
        XCTAssertEqual(games[1].start.timeIntervalSince(start) / 60, 18, accuracy: 1.5, "parted at the rest")
        XCTAssertEqual(Games.inSession(record: nil, stints: found, interval: interval, length: nil).count, 3, "blocks, until the length is known")
    }

    func testMarkedEndingsAreTheGames() throws {
        var record = MatchRecord(id: UUID(), startDate: start, endDate: start.addingTimeInterval(3600), fieldID: nil, events: [
            MatchEvent(kind: .goalForUs, date: start.addingTimeInterval(300)),
            MatchEvent(kind: .periodEnd, date: start.addingTimeInterval(720)),
            MatchEvent(kind: .goalAgainstUs, date: start.addingTimeInterval(1500)),
            MatchEvent(kind: .periodEnd, date: start.addingTimeInterval(1800))
        ], teamCode: nil, format: .indoor)
        let interval = DateInterval(start: start, duration: 3600)
        let games = Games.inSession(record: record, stints: nil, interval: interval, length: nil)
        XCTAssertEqual(games.map { $0.score }, [FinalScore(us: 1, them: 0), FinalScore(us: 0, them: 1), nil])
        XCTAssertEqual(Games.tally(games), GameTally(won: 1, drawn: 0, lost: 1))
        record.games = games
        record.games?[2].outcome = .won
        XCTAssertEqual(Games.tally(record.games ?? []), GameTally(won: 2, drawn: 0, lost: 1), "won is enough to say")
        let digest = MatchDigest(id: record.id, interval: interval, format: .indoor, record: record, analytics: nil)
        XCTAssertEqual(digest.goalsUs, 1)
    }

    func testHabitsAreLearnedForEachKindOfMatch() {
        var habits = PlayHabits()
        habits.learn(format: .indoor, keepsScore: false, games: 5, played: 60 * 60)
        XCTAssertEqual(habits[.indoor].keepsScore, false)
        XCTAssertEqual(habits[.indoor].gameSeconds, 720)
        XCTAssertNil(habits[.match].keepsScore, "a league match is another thing")
        habits.learn(format: .indoor, keepsScore: true, games: 1, played: 40 * 60)
        XCTAssertEqual(habits[.indoor].playsSeveralGames, false)
    }

    func testTwoHalvesArentTwoGamesUntilSomebodySays() throws {
        let (samples, interval) = heart([(3, false), (20, true), (10, false), (20, true), (3, false)])
        let analytics = try XCTUnwrap(MatchAnalyzer.analyze(MatchAnalysisInput(interval: interval, format: .indoor, heartRate: samples)))
        let record = MatchRecord(id: UUID(), startDate: start, endDate: interval.end, fieldID: nil,
                                 events: [MatchEvent(kind: .goalForUs, date: start.addingTimeInterval(600))], teamCode: nil, format: .indoor)
        let digest = MatchDigest(id: record.id, interval: interval, format: .indoor, record: record, analytics: analytics)
        XCTAssertNil(digest.games)
        XCTAssertEqual(digest.goalsUs, 1)
    }

    func testNobodyCounting() {
        var record = MatchRecord(id: UUID(), startDate: start, endDate: start.addingTimeInterval(3600), fieldID: nil, events: [
            MatchEvent(kind: .goalMine, date: start.addingTimeInterval(300))
        ], teamCode: nil, format: .indoor)
        record.keepsScore = false
        XCTAssertNil(record.score)
        let digest = MatchDigest(id: record.id, interval: DateInterval(start: start, duration: 3600), format: .indoor,
                                 record: record, analytics: nil)
        XCTAssertNil(digest.result)
        XCTAssertEqual(digest.myGoals, 1, "my goals are still mine")
    }
}
