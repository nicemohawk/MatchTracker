import XCTest
@testable import MatchTrackerKit

final class MatchRunsTests: XCTestCase {
    private let kickoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let field = OrientedRectangle(center: Coordinate2D(latitude: 0, longitude: 0), lengthMeters: 100, widthMeters: 60,
                                          headingDegrees: 0, corners: [])

    private func at(_ minute: Double) -> Date { kickoff.addingTimeInterval(minute * 60) }

    private func segment(_ minute: Double, seconds: TimeInterval = 5, speed: Double = 5) -> RunSegment {
        RunSegment(interval: DateInterval(start: at(minute), duration: seconds), distanceMeters: speed * seconds, peakSpeed: speed,
                   averageSpeed: speed, intensity: speed >= 5.5 ? .sprint : .run, pointRange: 0..<1)
    }

    private func runs(_ minutes: [Double], playing: [DateInterval], knowsDirection: Bool = true,
                      points: @escaping (RunSegment) -> [CGPoint] = { _ in [CGPoint(x: 0.5, y: 0.4), CGPoint(x: 0.5, y: 0.6)] }) -> [MatchRun] {
        MatchRun.all(from: minutes.map { segment($0) }, points: points, keyRuns: [], field: field,
                     knowsDirection: knowsDirection, playing: playing, start: kickoff)
    }

    func testWhichWayARunWent() {
        func heading(_ from: (Double, Double), _ to: (Double, Double)) -> MatchRun.Heading? {
            MatchRun.heading(of: [CGPoint(x: from.0, y: from.1), CGPoint(x: to.0, y: to.1)], in: field)
        }
        XCTAssertEqual(heading((0.5, 0.4), (0.5, 0.7)), .forward)
        XCTAssertEqual(heading((0.5, 0.7), (0.6, 0.3)), .back)
        XCTAssertEqual(heading((0.1, 0.5), (0.7, 0.52)), .across)
        XCTAssertEqual(heading((0.5, 0.5), (0.5, 0.53)), .across, "Three meters is a turn, not a direction")
        XCTAssertNil(MatchRun.heading(of: [], in: field))
    }

    func testARunIsToldAsAStory() {
        let playing = [DateInterval(start: kickoff, duration: 5400)]
        let wing = runs([1], playing: playing) { _ in [CGPoint(x: 0.9, y: 0.5), CGPoint(x: 0.8, y: 0.75), CGPoint(x: 0.75, y: 0.9)] }
        XCTAssertEqual(wing[0].story, "Forward down the right, into the box")
        let recovery = runs([1], playing: playing) { _ in [CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.1, y: 0.3)] }
        XCTAssertEqual(recovery[0].story, "Back down the left, from the final third")
        XCTAssertNil(runs([1], playing: playing, knowsDirection: false)[0].story)
    }

    func testRestsAreBetweenRunsOfTheSameSpell() {
        let playing = [DateInterval(start: at(0), end: at(20)), DateInterval(start: at(30), end: at(50))]
        let all = runs([2, 5, 19, 32, 34], playing: playing)
        XCTAssertNil(all[0].gapBefore)
        XCTAssertEqual(all[1].gapBefore ?? 0, 175, accuracy: 0.1)
        XCTAssertNil(all[3].gapBefore, "Ten minutes on the bench isn't a rest between runs")
        XCTAssertNotNil(all[4].gapBefore)
    }

    func testFadingIsForTheTimePlayed() {
        let halftime = DateInterval(start: at(45), end: at(55))
        let playing = [DateInterval(start: at(0), end: at(45)), DateInterval(start: at(55), end: at(100))]
        let fading = RunReport(runs: runs([1, 5, 9, 14, 20, 25, 30, 40, 60, 70], playing: playing), playing: playing, halftime: halftime)
        XCTAssertEqual(fading.halves?.first ?? 0, 10.7, accuracy: 0.1)
        XCTAssertEqual(fading.headline, "You ran less after half-time: 75% fewer runs for the time you played.")
        // A quarter of an hour of the second half, with a quarter of the runs, isn't fading.
        let subbed = [DateInterval(start: at(0), end: at(45)), DateInterval(start: at(55), end: at(70))]
        let steady = RunReport(runs: runs([1, 5, 9, 14, 20, 25, 57, 65], playing: subbed), playing: subbed, halftime: halftime)
        XCTAssertFalse(steady.headline?.contains("less") ?? false)
    }

    func testTheBusiestSpellHasToStandOut() {
        let playing = [DateInterval(start: at(0), end: at(90))]
        let even = RunReport(runs: runs(stride(from: 2.0, to: 88, by: 8).map { $0 }, playing: playing), playing: playing, halftime: nil)
        XCTAssertNil(even.busiest)
        let burst = RunReport(runs: runs([2, 30, 31, 33, 35, 38, 70, 85], playing: playing), playing: playing, halftime: nil)
        XCTAssertEqual(burst.busiest?.count, 5)
        XCTAssertEqual(burst.busiest?.start, at(30))
    }

    func testNothingIsSaidOfAFewRuns() {
        let playing = [DateInterval(start: at(0), end: at(90))]
        let few = RunReport(runs: runs([2, 30], playing: playing), playing: playing, halftime: nil)
        XCTAssertNil(few.headline)
        XCTAssertNil(few.typicalGap)
        XCTAssertNil(RunReport(runs: [], playing: [], halftime: nil).busiest)
    }
}
