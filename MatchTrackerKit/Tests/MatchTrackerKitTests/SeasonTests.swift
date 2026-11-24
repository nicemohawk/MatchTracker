import XCTest
@testable import MatchTrackerKit

final class SeasonTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func digest(_ day: Int, us: Int? = nil, them: Int? = nil, distance: Double? = nil,
                        speed: Double? = nil, minutes: Double = 90, format: MatchFormat = .match) -> MatchDigest {
        let start = base.addingTimeInterval(Double(day) * 86_400)
        var digest = MatchDigest(id: UUID(), startDate: start, endDate: start.addingTimeInterval(minutes * 60), format: format)
        digest.goalsUs = us
        digest.goalsThem = them
        digest.distanceMeters = distance
        digest.topSpeedMetersPerSecond = speed
        return digest
    }

    func testRecordIgnoresMatchesWithoutAScore() {
        let season = SeasonSummary([digest(0, us: 3, them: 1), digest(1, us: 0, them: 0), digest(2)])
        XCTAssertEqual([season.won, season.drawn, season.lost], [1, 1, 0])
    }

    func testEqualingABestIsNotSettingOne() {
        let first = digest(0, speed: 7), second = digest(1, speed: 8), third = digest(2, speed: 8)
        let season = SeasonSummary([third, first, second])
        XCTAssertEqual(season.bestsSet(by: third.id), [])
        XCTAssertEqual(season.holder(of: .topSpeed)?.digest.id, second.id)
    }

    func testFirstMatchesSetNoBests() {
        let first = digest(0, speed: 7), second = digest(1, speed: 8)
        XCTAssertEqual(SeasonSummary([first, second]).bestsSet(by: second.id), [])
    }

    func testForgottenMatchIsNotTheLongest() {
        let forgotten = digest(0, minutes: 1913)
        XCTAssertNil(PersonalBest.longestMatch.value(in: forgotten))
    }

    func testTerms() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let fall = SeasonSummary.Term(containing: base, calendar: calendar)   // September 2026
        XCTAssertEqual(fall.title, "Fall 2026")
        XCTAssertLessThan(SeasonSummary.Term(containing: base.addingTimeInterval(-200 * 86_400), calendar: calendar), fall)
    }

    func testHeadlinePrefersABest() {
        let history = [digest(0, distance: 7000, speed: 7), digest(1, distance: 7000, speed: 7.5)]
        let latest = digest(2, distance: 5000, speed: 8)
        XCTAssertEqual(MatchHeadline.make(for: latest, among: history, units: .imperial),
                       "Your fastest yet: 17.9 mph.")
    }

    func testHeadlineComparesPerHourWithinTheFormat() {
        let history = (0..<4).map { digest($0, distance: 6000, speed: 8) }
            + [digest(4, distance: 100, speed: 8, format: .indoor)]
        // Half the minutes and half the distance is the same pace, not "less".
        XCTAssertEqual(MatchHeadline.make(for: digest(9, distance: 3000, speed: 7, minutes: 45), among: history),
                       "About as much running as usual.")
        XCTAssertEqual(MatchHeadline.make(for: digest(9, distance: 5000, speed: 7), among: history, units: .metric),
                       "You covered 1.00 km less than usual.")
    }

    func testHeadlineSaysNothingWithoutHistory() {
        XCTAssertNil(MatchHeadline.make(for: digest(0, distance: 5000), among: []))
    }
}
