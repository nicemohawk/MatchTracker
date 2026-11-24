import XCTest
@testable import MatchTrackerKit

final class FixturesTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ title: String, hour: Double = 0, minutes: Double = 90) -> CalendarEvent {
        let start = base.addingTimeInterval(hour * 3600)
        return CalendarEvent(id: "\(title)\(hour)", title: title, start: start, end: start.addingTimeInterval(minutes * 60))
    }

    private func parse(_ title: String) -> Fixture? {
        FixtureParser.fixture(from: event(title), teamNames: ["Red Dragons"])
    }

    func testOpponentFromCommonTitles() {
        let expected = [
            ("Red Dragons vs. Rovers FC", "Rovers FC"),
            ("Rovers FC v Red Dragons", "Rovers FC"),
            ("⚽️ Red Dragons vs Rovers FC - Field 3", "Rovers FC"),
            ("vs Rovers", "Rovers"),
            ("Game vs. Rovers (Home)", "Rovers"),
            ("Red Dragons at Rovers", "Rovers"),
            ("Rovers @ Red Dragons", "Rovers"),
            ("U14 Red Dragons - Game vs Rovers @ Riverside Park", "Rovers"),
            ("Match: Rovers (A)", "Rovers"),
            ("Friendly - St. Mary's", "St. Mary's"),
            ("Kamp mot Brann", "Brann"),
            ("League game 4: Rovers", "Rovers"),
            ("Red Dragons vs Rovers, Pitch 2", "Rovers"),
            ("Practice match vs Rovers", "Rovers")
        ]
        for (title, opponent) in expected {
            XCTAssertEqual(parse(title)?.opponent, opponent, title)
        }
    }

    func testVenue() {
        XCTAssertEqual(parse("Red Dragons at Rovers")?.venue, .away)
        XCTAssertEqual(parse("Rovers @ Red Dragons")?.venue, .home)
        XCTAssertEqual(parse("Rovers v Red Dragons")?.venue, .away)
        XCTAssertEqual(parse("Game vs Rovers (H)")?.venue, .home)
        XCTAssertNil(parse("Game vs Rovers")?.venue)
    }

    func testMatchesWithoutAnOpponent() {
        for title in ["Match", "Soccer game", "League game 3", "Game at Riverside Park", "Red Dragons vs TBD"] {
            XCTAssertNotNil(parse(title), title)
            XCTAssertNil(parse(title)?.opponent, title)
        }
    }

    func testEverythingElseIsIgnored() {
        for title in ["Practice", "Training with Sam", "Dinner at Joe's", "Dentist", "Game night", "Basketball game vs Rovers",
                      "CANCELED: Red Dragons vs Rovers", "Red Dragons vs Rovers (postponed)", "Team party", "Cup of coffee", ""] {
            XCTAssertNil(parse(title), title)
        }
        var allDay = event("Red Dragons vs Rovers")
        allDay.isAllDay = true
        XCTAssertNil(FixtureParser.fixture(from: allDay, teamNames: []))
        var canceled = event("Red Dragons vs Rovers")
        canceled.isCanceled = true
        XCTAssertNil(FixtureParser.fixture(from: canceled, teamNames: []))
    }

    func testLearnsOwnNameFromTheCalendar() {
        let fixtures = FixtureParser.fixtures(in: [
            event("Harbor United vs Rovers"), event("Albion vs Harbor United", hour: 100),
            event("Harbor United vs City", hour: 200), event("Practice", hour: 250)
        ])
        XCTAssertEqual(fixtures.map(\.opponent), ["Rovers", "Albion", "City"])
    }

    func testMissingEndBecomesTwoHours() {
        let fixture = FixtureParser.fixture(from: event("vs Rovers", minutes: 0), teamNames: [])
        XCTAssertEqual(fixture.map { $0.end.timeIntervalSince($0.start) }, 7200)
    }

    func testFieldByPlaceThenName() {
        let here = Coordinate2D(latitude: 39.325, longitude: -82.101)
        let rectangle = OrientedRectangle(center: here, lengthMeters: 100, widthMeters: 60, headingDegrees: 0, corners: [])
        let field = FieldModel(id: UUID(), name: "Demo Park", createdAt: base, outline: [], rectangle: rectangle,
                               source: .trained, observationCount: 1)
        func match(_ location: String?, _ coordinate: Coordinate2D?) -> UUID? {
            Fixture(id: "a", title: "a", location: location, coordinate: coordinate, start: base, end: base)
                .field(among: [field])?.id
        }
        XCTAssertEqual(match(nil, Coordinate2D(latitude: 39.3265, longitude: -82.101)), field.id)
        XCTAssertEqual(match("Demo Park, 12 Main St", nil), field.id)
        XCTAssertNil(match("Somewhere else", nil))
        // A coordinate outranks a name: two parks can share one.
        XCTAssertNil(match("Demo Park", Coordinate2D(latitude: 40, longitude: -82)))
    }

    func testRecordingFindsItsFixture() {
        let morning = Fixture(id: "1", title: "", opponent: "Rovers", start: base, end: base.addingTimeInterval(5400))
        let noon = Fixture(id: "2", title: "", opponent: "City", start: base.addingTimeInterval(7200), end: base.addingTimeInterval(12_600))
        func find(_ startMinutes: Double, _ endMinutes: Double) -> String? {
            FixtureMatcher.fixture(forMatchFrom: base.addingTimeInterval(startMinutes * 60),
                                   to: base.addingTimeInterval(endMinutes * 60), among: [morning, noon])?.opponent
        }
        XCTAssertEqual(find(5, 95), "Rovers")
        XCTAssertEqual(find(125, 220), "City")
        XCTAssertEqual(find(30, 130), "Rovers")
        XCTAssertNil(find(-400, -300))
        XCTAssertNil(find(600, 690))
    }

    func testRecordingFarFromTheFixtureIsAnotherMatch() {
        let fixture = Fixture(id: "1", title: "", opponent: "Rovers", coordinate: Coordinate2D(latitude: 39, longitude: -82),
                              start: base, end: base.addingTimeInterval(5400))
        XCTAssertNil(FixtureMatcher.fixture(forMatchFrom: base, to: base.addingTimeInterval(5400),
                                            at: Coordinate2D(latitude: 40, longitude: -82), among: [fixture]))
    }
}
