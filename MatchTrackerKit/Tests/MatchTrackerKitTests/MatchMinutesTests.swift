import XCTest
@testable import MatchTrackerKit

final class MatchMinutesTests: XCTestCase {
    private let kickoff = Date(timeIntervalSince1970: 1_700_000_000)

    private func minutes(halftime: (from: Double, to: Double)? = (2600, 3260)) -> MatchMinutes {
        MatchMinutes(kickoff: kickoff, halftime: halftime.map { DateInterval(start: at($0.from), end: at($0.to)) })
    }

    private func at(_ seconds: Double) -> Date { kickoff.addingTimeInterval(seconds) }

    func testTheFirstMinuteIsOne() {
        XCTAssertEqual(minutes().minute(of: at(0)), 1)
        XCTAssertEqual(minutes().minute(of: at(59)), 1)
        XCTAssertEqual(minutes().minute(of: at(60)), 2)
        XCTAssertEqual(minutes().minute(of: at(-90)), 1)
    }

    func testTheClockStopsForHalfTime() {
        XCTAssertEqual(minutes().minute(of: at(2599)), 44)
        XCTAssertEqual(minutes().minute(of: at(3260)), 44, "the second half carries on from where the first stopped")
        XCTAssertEqual(minutes().minute(of: at(3300)), 45)
        XCTAssertEqual(minutes().playedSeconds(at: at(3600)), 2940)
    }

    func testHalfTimeSaysSo() {
        XCTAssertEqual(minutes().text(for: at(2599)), "44′")
        XCTAssertEqual(minutes().text(for: at(2600)), "HT")
        XCTAssertEqual(minutes().text(for: at(3259)), "HT")
        XCTAssertEqual(minutes().text(for: at(3260)), "44′")
        XCTAssertEqual(minutes().spoken(for: at(3000)), "Half-time")
        XCTAssertEqual(minutes().spoken(for: at(60)), "Minute 2")
    }

    func testWithoutAHalfTimeEveryMinuteCounts() {
        XCTAssertEqual(minutes(halftime: nil).minute(of: at(3600)), 61)
        XCTAssertEqual(minutes(halftime: nil).text(for: at(3000)), "51′")
        XCTAssertEqual(minutes(halftime: nil).date(ofMinute: 61), at(3630))
    }

    func testAHalfTimeTrimmedIntoCountsOnlyWhatIsLeft() {
        let minutes = minutes(halftime: (-300, 120))
        XCTAssertEqual(minutes.playedSeconds(at: at(180)), 60)
        XCTAssertEqual(minutes.date(ofMinute: 1), at(150))
    }

    func testEveryMinuteComesBackAsItself() {
        let halftimes: [(from: Double, to: Double)?] = [nil, (2600, 3260), (2700, 3600), (2659, 2660), (-600, -300)]
        for halftime in halftimes {
            let minutes = minutes(halftime: halftime)
            for minute in 1...100 {
                let date = minutes.date(ofMinute: minute)
                XCTAssertEqual(minutes.minute(of: date), minute)
                XCTAssertFalse(minutes.isHalftime(date), "a minute is always in play")
            }
        }
    }
}
