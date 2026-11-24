// SmokeTests.swift
// MatchTracker UITests
//
// The life of a match on the phone, driven through the real app on a simulator with made-up
// matches. Never run these where somebody's own history lives: they delete a match.

import XCTest

final class SmokeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // Nothing made up may reach the server.
        app.launchArguments += ["-hasOnboarded", "YES", "-asksAfterMatches", "NO", "-serverURLOverride", "http://127.0.0.1:9"]
    }

    func testAMatchIsListedScoredAndDeleted() throws {
        app.launch()
        handleHealthKitPrompt(app: app)
        XCTAssertTrue(app.navigationBars["Summary"].waitForExistence(timeout: 20), "Summary opens first")
        generateSeason()

        XCTAssertTrue(selectTab("Matches", expectingNavBar: "Matches", in: app))
        let rows = app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS 'Demo Park'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "The made-up season should be listed")
        rows.firstMatch.tap()
        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 20), "A row opens its match")

        setScore(us: 7)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '7 to 0'")).firstMatch.waitForExistence(timeout: 10),
                      "The result is on the match")

        relaunch()
        XCTAssertTrue(selectTab("Matches", expectingNavBar: "Matches", in: app))
        let scored = app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS 'Won 7 to 0'")).firstMatch
        XCTAssertTrue(scored.waitForExistence(timeout: 20), "The result outlives the app")

        scored.tap()
        app.buttons["More"].tap()
        app.buttons["Delete Match"].tap()
        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Delete Match"].tap()
        XCTAssertTrue(app.navigationBars["Matches"].waitForExistence(timeout: 10))

        relaunch()
        XCTAssertTrue(selectTab("Matches", expectingNavBar: "Matches", in: app))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20), "The other matches are still there")
        XCTAssertFalse(scored.exists, "A deleted match stays deleted")
    }

    func testTabsRender() {
        app.launch()
        handleHealthKitPrompt(app: app)
        XCTAssertTrue(app.navigationBars["Summary"].waitForExistence(timeout: 20))
        XCTAssertTrue(selectTab("Matches", expectingNavBar: "Matches", in: app))
        XCTAssertTrue(selectTab("Team", expectingNavBar: "Team", in: app))
        XCTAssertTrue(selectTab("Summary", expectingNavBar: "Summary", in: app))
        XCTAssertTrue(openSettings(app: app))
        closeSettings(app: app)
    }

    /// Nobody else, no coach, no subscription.
    func testACaptainStartsATeamAndLeavesIt() {
        app.launchArguments += ["-TeamStub", "new"]
        app.launch()
        handleHealthKitPrompt(app: app)
        XCTAssertTrue(selectTab("Team", expectingNavBar: "Team", in: app))
        app.buttons["Start a Team"].tap()
        let teamName = app.textFields["Team name"]
        XCTAssertTrue(teamName.waitForExistence(timeout: 5))
        teamName.tap()
        teamName.typeText("Red Dragons")
        let playerName = app.textFields["Name or initials"]
        playerName.tap()
        playerName.typeText("Cap")
        app.navigationBars.buttons["Start"].tap()
        XCTAssertTrue(app.buttons["Send Invite"].waitForExistence(timeout: 5), "The invite comes straight after the name")
        app.buttons["Done"].tap()

        XCTAssertTrue(app.navigationBars["Red Dragons"].waitForExistence(timeout: 5))
        app.buttons["Formation"].tap()
        app.buttons["Set Up by Hand"].tap()
        app.buttons["Add a player"].tap()
        app.buttons["Someone Else…"].tap()
        let added = app.alerts["Add a Player"].textFields.firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        added.typeText("Maya Ortiz")
        app.alerts["Add a Player"].buttons["Add"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["Maya Ortiz"].waitForExistence(timeout: 5), "A teammate without the app has a place")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Who's in"].tap()
        XCTAssertTrue(app.buttons["Maya Ortiz"].waitForExistence(timeout: 5))
        app.buttons["Maya Ortiz"].tap()
        XCTAssertTrue(app.staticTexts["1 in"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["Manage team"].tap()
        XCTAssertTrue(app.navigationBars["Manage Team"].waitForExistence(timeout: 5))
        let leave = app.buttons["Leave Red Dragons"]
        XCTAssertTrue(scrollUntilHittable(leave, in: app))
        leave.tap()
        app.alerts.buttons["Leave Team"].tap()
        XCTAssertTrue(app.buttons["Start a Team"].waitForExistence(timeout: 5), "Leaving the only team goes back to the start")
    }

    func testAnInviteLinkOpensTheJoinScreen() {
        app.launchArguments += ["-TeamStub", "new"]
        app.launch()
        handleHealthKitPrompt(app: app)
        app.open(URL(string: "matchtracker-join://K7QM2P?team=Red%20Dragons&captain=Maya%20Ortiz")!)
        XCTAssertTrue(app.navigationBars["Join a Team"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Red Dragons"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Start a Team"].waitForExistence(timeout: 5), "A link only asks; it never joins by itself")
    }

    // MARK: - Steps

    private func generateSeason() {
        XCTAssertTrue(openSettings(app: app))
        let generate = app.buttons["Generate Sample Season (5)"]
        XCTAssertTrue(scrollUntilHittable(generate, in: app), "Debug builds can make up a season")
        generate.tap()
        handleHealthKitPrompt(app: app)
        let done = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Generated sample season'")).firstMatch
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, !done.exists {
            app.swipeUp(velocity: .slow)
            _ = done.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(done.exists, "The season should finish generating")
        closeSettings(app: app)
    }

    private func setScore(us target: Int) {
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Demo Park' OR label CONTAINS 'Add the Score' OR label CONTAINS 'Won' OR label CONTAINS 'Lost' OR label CONTAINS 'Drew'"))
            .firstMatch.tap()
        XCTAssertTrue(app.navigationBars["How Did It End?"].waitForExistence(timeout: 5))
        set(app.steppers["Us"], to: target, shownIn: 0)
        set(app.steppers["Them"], to: 0, shownIn: 1)
        app.buttons["Save"].tap()
    }

    /// The two counts are the only bare numbers on the sheet, us then them.
    private func set(_ stepper: XCUIElement, to target: Int, shownIn index: Int) {
        let counts = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+$'"))
        for _ in 0..<40 {
            guard let value = Int(counts.element(boundBy: index).label), value != target else { return }
            stepper.buttons.element(boundBy: value < target ? 1 : 0).tap()
        }
    }

    private func relaunch() {
        app.terminate()
        app.launch()
    }
}
