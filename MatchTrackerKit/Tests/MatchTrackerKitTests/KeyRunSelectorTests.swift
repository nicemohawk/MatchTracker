import XCTest
@testable import MatchTrackerKit

final class KeyRunSelectorTests: XCTestCase {

    private let interval = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 90 * 60)

    private func run(at minute: Double, distance: Double, peak: Double, seconds: Double = 8) -> RunSegment {
        let start = interval.start.addingTimeInterval(minute * 60)
        return RunSegment(interval: DateInterval(start: start, duration: seconds), distanceMeters: distance,
                          peakSpeed: peak, averageSpeed: peak * 0.7,
                          intensity: peak >= SpeedThresholds.sprinting ? .sprint : .run, pointRange: 0..<2)
    }

    private func select(_ runs: [RunSegment], goals: [(MatchEventKind, Double)] = []) -> [KeyRun] {
        KeyRunSelector.select(runs: runs, events: goals.map {
            MatchEvent(kind: $0.0, date: interval.start.addingTimeInterval($0.1 * 60))
        }, interval: interval)
    }

    func testFastestLongestAndDecisive() {
        let runs = [run(at: 10, distance: 25, peak: 7.5), run(at: 20, distance: 60, peak: 5), run(at: 30, distance: 30, peak: 4.5)]
        let chosen = select(runs, goals: [(.goalMine, 30.3)])
        XCTAssertEqual(chosen.map(\.title), ["Fastest run", "Longest run", "Run just before your goal"])
        XCTAssertEqual(chosen.map(\.id), runs.map(\.id))
        XCTAssertEqual(chosen[0].fromT, 600)
        XCTAssertEqual(chosen[0].toT, 608)
    }

    func testOneRunWinningTwiceAppearsOnce() {
        let best = run(at: 10, distance: 60, peak: 8)
        let chosen = select([best, run(at: 20, distance: 40, peak: 6)], goals: [(.goalForUs, 10.2)])
        XCTAssertEqual(chosen.map(\.title), ["Fastest and longest run, just before we scored"])
        XCTAssertEqual(chosen.first?.categories, [.fastest, .longest, .decisive])
    }

    func testNothingQualifiesBelowThirtyYardsAndSprintSpeed() {
        XCTAssertTrue(select([run(at: 10, distance: 20, peak: 5), run(at: 30, distance: 27, peak: 5.4)],
                             goals: [(.goalMine, 30.2)]).isEmpty)
        XCTAssertEqual(select([run(at: 10, distance: 12, peak: 5.6)]).count, 1)
        XCTAssertEqual(select([run(at: 10, distance: 28, peak: 4.2)]).count, 1)
    }

    func testDecisiveMustEndJustBeforeOwnGoal() {
        let fastest = run(at: 5, distance: 60, peak: 8)
        let other = run(at: 40, distance: 30, peak: 6)
        XCTAssertEqual(select([fastest, other], goals: [(.goalAgainstUs, 40.3), (.goalForUs, 39), (.goalForUs, 41.5)]).count, 1)
    }

    func testOwnGoalOutranksTheTeams() {
        let runs = [run(at: 5, distance: 60, peak: 8), run(at: 20, distance: 30, peak: 7), run(at: 40, distance: 30, peak: 6)]
        XCTAssertEqual(select(runs, goals: [(.goalForUs, 20.3), (.goalMine, 40.3)]).last?.title, "Run just before your goal")
        XCTAssertEqual(select(runs, goals: [(.goalForUs, 20.3), (.assist, 40.3)]).last?.title, "Run just before your assist")
    }

    func testSelectionIsDeterministic() {
        let runs = [run(at: 70, distance: 40, peak: 7), run(at: 10, distance: 40, peak: 7), run(at: 80, distance: 40, peak: 7)]
        XCTAssertEqual(select(runs).map(\.id), select(runs.reversed()).map(\.id))
        XCTAssertEqual(select(runs).map(\.id), [runs[1].id], "the earlier of equals has the claim")
        XCTAssertNil(select(runs).first?.detail)
        XCTAssertEqual(select([runs[2]]).first?.detail, "Late in the match")
    }
}
