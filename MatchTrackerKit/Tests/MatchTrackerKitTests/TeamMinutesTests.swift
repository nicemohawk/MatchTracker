import XCTest
@testable import MatchTrackerKit

final class TeamMinutesTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func events(_ player: String, day: Double = 0, _ timeline: [(MatchEventKind, Double)]) -> [TeamEvent] {
        let match = UUID()
        return timeline.map { kind, minute in
            TeamEvent(playerName: player, matchUUID: match, kindRawValue: kind.rawValue,
                      date: base.addingTimeInterval(day * 86_400 + minute * 60))
        }
    }

    func testBenchAndHalfTimeComeOff() {
        let match = TeamMinutes.matches(from:
            events("Maya", [(.matchStart, 0), (.periodEnd, 45), (.periodStart, 60), (.matchEnd, 105)])
            + events("Sam", [(.matchStart, 2), (.subOut, 32), (.subIn, 62), (.matchEnd, 102)])
            + events("Ana", [(.matchStart, 0), (.subIn, 70), (.matchEnd, 100)])
            + events("Lou", [(.matchStart, 0), (.subOut, 40), (.periodEnd, 45), (.periodStart, 60), (.matchEnd, 105)])
        ).first
        XCTAssertEqual(match?.minutesByPlayer, ["Maya": 90, "Sam": 70, "Ana": 30, "Lou": 40])
    }

    func testAutomaticBenchStintAroundHalfTime() {
        let match = TeamMinutes.matches(from: events("Maya", [
            (.matchStart, 0), (.subOut, 45), (.periodEnd, 45), (.periodStart, 60), (.subIn, 60), (.matchEnd, 105)
        ])).first
        XCTAssertEqual(match?.minutesByPlayer["Maya"], 90)
        XCTAssertEqual(match?.lengthMinutes, 90)
    }

    func testKickoffsCloseTogetherAreOneMatch() {
        let matches = TeamMinutes.matches(from:
            events("Maya", [(.matchStart, 0), (.matchEnd, 90)])
            + events("Sam", [(.matchStart, 4), (.matchEnd, 92)])
            + events("Maya", day: 7, [(.matchStart, 0), (.matchEnd, 90)]))
        XCTAssertEqual(matches.map(\.minutesByPlayer.count), [1, 2])
    }

    func testForgottenAndSingleEventRecordingsAreLeftOut() {
        XCTAssertTrue(TeamMinutes.matches(from: events("Maya", [(.matchStart, 0), (.matchEnd, 600)])
            + events("Sam", [(.goalMine, 10)])).isEmpty)
    }

    func testLoadInWords() {
        let matches = (0..<5).map { index in
            TeamMatchMinutes(kickoff: base.addingTimeInterval(Double(-index) * 86_400), lengthMinutes: 90,
                             minutesByPlayer: index == 0 ? ["Maya": 90, "Sam": 45, "Ana": 20] : ["Maya": 88, "Sam": 45])
        }
        XCTAssertEqual(RecentLoad(player: "Maya", matches: matches).summary, "Nearly every minute")
        XCTAssertEqual(RecentLoad(player: "Sam", matches: matches).summary, "Regular minutes")
        XCTAssertEqual(RecentLoad(player: "Ana", matches: matches).summary, "Only one match lately")
        XCTAssertEqual(RecentLoad(player: "Lou", matches: matches).summary, "Nothing recorded lately")
        XCTAssertEqual(RecentLoad(player: "Ana", matches: matches).perMatch, [nil, nil, nil, nil, 20])
        XCTAssertEqual(RecentLoad(player: "Ana", matches: []).summary, "No recent matches")
    }

    func testInviteRoundTrips() {
        let invite = TeamInvite(code: "K7QM2P", name: "Red Dragons")
        XCTAssertEqual(TeamInvite(pasted: invite.message), invite)
        let unnamed = TeamInvite(code: "ABC123", name: nil)
        XCTAssertEqual(TeamInvite(pasted: unnamed.message), unnamed)
        XCTAssertEqual(TeamInvite(pasted: " u14-red "), TeamInvite(code: "U14-RED", name: nil))
        XCTAssertNil(TeamInvite(pasted: "hello there"))
        XCTAssertNil(TeamInvite(pasted: ""))
        XCTAssertNotNil(TeamInvite(pasted: TeamInvite.newCode()))
    }

    func testFormationNameFromDepths() {
        XCTAssertEqual(FormationShape.name(depths: FormationShape.startingPoints.map(\.x)), "4-3-3")
        XCTAssertNil(FormationShape.name(depths: [0.1, 0.2, 0.3]))
    }

    func testRolesInWords() {
        XCTAssertEqual(FormationShape.role(x: 0.06, y: 0.5), "Goalkeeper")
        XCTAssertEqual(FormationShape.role(x: 0.25, y: 0.1), "Left back")
        XCTAssertEqual(FormationShape.role(x: 0.5, y: 0.5), "Central midfielder")
        XCTAssertEqual(FormationShape.role(x: 0.8, y: 0.5), "Striker")
    }
}
