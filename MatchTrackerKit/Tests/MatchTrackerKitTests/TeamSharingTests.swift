import XCTest
@testable import MatchTrackerKit

final class TeamSharingTests: XCTestCase {
    private let kickoff = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var before: Date { kickoff.addingTimeInterval(-3600) }
    private var after: Date { kickoff.addingTimeInterval(3600) }

    private func code(_ recorded: String?, _ chosen: String, at chosenAt: Date?) -> String? {
        TeamSharing.code(recorded: recorded, chosen: chosen, chosenAt: chosenAt, start: kickoff)
    }

    func testNobodyStaysNobodyWhenATeamIsChosenAfterwards() {
        XCTAssertNil(code("", "A", at: after))
        XCTAssertNil(code(nil, "A", at: after))
    }

    func testNobodyOnThePhoneBeatsAWatchThatHadNotHeard() {
        XCTAssertNil(code("A", "", at: before))
    }

    func testATeamChosenBeforeKickoffBeatsAWatchThatHadNotHeard() {
        XCTAssertEqual(code("", "B", at: before), "B")
        XCTAssertEqual(code("A", "B", at: before), "B")
    }

    func testTheTeamAtTheTimeStandsWhenItsChangedAfterwards() {
        XCTAssertEqual(code("A", "B", at: after), "A")
        XCTAssertEqual(code("A", "", at: after), "A")
    }

    func testChoicesMadeBeforeTheyWereDated() {
        XCTAssertEqual(code("A", "B", at: nil), "A")
        XCTAssertEqual(code(nil, "B", at: nil), "B")
        XCTAssertNil(code("", "B", at: nil))
    }

    func testAHandTypedCodeMakesAnInviteWithoutALink() {
        let invite = TeamInvite(code: "TIGERS FC", name: "Tigers")
        XCTAssertNil(invite.link)
        XCTAssertTrue(invite.message.contains("TIGERS FC"))
        XCTAssertNotNil(TeamInvite(code: "K7QM2P", name: "Tigers").link)
    }
}
