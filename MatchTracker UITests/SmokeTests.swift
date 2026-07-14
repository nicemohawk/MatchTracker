// SmokeTests.swift
// MatchTracker UITests
//
// End-to-end smoke coverage that drives the real app on the simulator: generates a synthetic
// season (which exercises the HealthKit authorization flow), browses the resulting matches, and
// verifies each top-level tab renders. Elements are located by visible label text / system queries
// only — no app-side accessibilityIdentifiers.

import XCTest

final class SmokeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launches, generates a 5-match sample season through the Developer tools (driving the
    /// HealthKit permission sheet), and browses into the first match.
    func testGenerateSeasonAndBrowse() {
        let app = XCUIApplication()
        app.launchArguments += ["-MatchTrackerEntitleTeam"]
        app.launch()

        // The app requests HealthKit authorization during bootstrap, so the "Health Access" sheet
        // comes up over everything the moment the app launches. Drive it first — otherwise it
        // covers the settings button and tab bar.
        screenshot("00-launch-hk-sheet")
        handleHealthKitPrompt(app: app)

        // Matches list is the launch tab.
        XCTAssertTrue(app.navigationBars["Matches"].waitForExistence(timeout: 20),
                      "Matches nav bar should appear on launch")
        screenshot("01-launch")

        // Open the global settings sheet.
        XCTAssertTrue(openSettings(app: app), "Should be able to open Settings")
        screenshot("02-settings-open")

        // Kick off sample-season generation (Developer section, DEBUG builds). The Developer
        // section sits at the bottom of a lazy SwiftUI Form, so scroll it into view first.
        let generate = app.buttons["Generate Sample Season (5)"]
        XCTAssertTrue(scrollUntilHittable(generate, in: app),
                      "'Generate Sample Season (5)' button should exist in Developer section")
        generate.tap()

        // Generating a season writes HealthKit workouts, which triggers the authorization sheet.
        handleHealthKitPrompt(app: app)

        // Wait for the completion caption. Season generation runs the full analysis pipeline (up to
        // ~2 min). The caption sits at the bottom of a lazy Form, so poll while nudging the section
        // into view; also fail fast if an error caption appears instead.
        let completion = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'Generated sample season'")).firstMatch
        let failure = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Failed'")).firstMatch
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline && !completion.exists {
            if failure.exists { XCTFail("Season generation failed: \(failure.label)"); break }
            app.swipeUp(velocity: .slow) // keep the caption row rendered (lazy Form) and in view
            _ = completion.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(completion.exists, "Season generation should report completion")
        screenshot("03-season-generated")

        // Close settings and return to the Matches list. Generation may have prompted for location
        // (field seeding), so clear any stray system alert, and fall back to tapping the tab.
        closeSettings(app: app)
        dismissLocationPromptIfPresent(timeout: 3)
        screenshot("03b-after-close-settings")
        if !app.navigationBars["Matches"].waitForExistence(timeout: 8) {
            selectTab("Matches", expectingNavBar: "Matches", in: app)
        }
        XCTAssertTrue(app.navigationBars["Matches"].waitForExistence(timeout: 10),
                      "Should return to Matches after closing Settings")

        // The generated matches are all on "Demo Park". Each List row is a NavigationLink exposed as
        // a button whose aggregate label includes the (distinct) date and the field name. Not all 5
        // fit on screen, and the List renders lazily, so accumulate DISTINCT row labels across a
        // downward scroll sweep rather than counting what's momentarily visible.
        let demoParkPredicate = NSPredicate(format: "label CONTAINS[c] 'Demo Park'")
        let demoParkRowButtons = app.buttons.matching(demoParkPredicate)
        XCTAssertTrue(waitForElement(demoParkRowButtons.firstMatch, timeout: 20),
                      "At least one 'Demo Park' match row should appear")
        var seenRows = Set<String>()
        for _ in 0..<6 {
            let rows = app.buttons.matching(demoParkPredicate)
            for index in 0..<rows.count {
                let label = rows.element(boundBy: index).label
                if !label.isEmpty { seenRows.insert(label) }
            }
            if seenRows.count >= 5 { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertGreaterThanOrEqual(seenRows.count, 5,
                                    "Expected at least 5 Demo Park matches, saw \(seenRows.count)")
        screenshot("04-matches-list")

        // Open the first match. Scroll back to the top, then tap the first Demo Park row.
        app.swipeDown(velocity: .fast)
        app.swipeDown(velocity: .fast)
        let firstRow = app.buttons.matching(demoParkPredicate).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "A Demo Park match row should exist")
        firstRow.tap()
        // The detail opens on the heatmap (a map view), which may request location. Grant/clear it
        // so it doesn't sit over the section chips.
        dismissLocationPromptIfPresent(timeout: 4)

        // Detail header shows "Workrate" (rendered uppercase as WORKRATE via textCase).
        let workrate = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'workrate'")).firstMatch
        XCTAssertTrue(waitForElement(workrate, timeout: 20),
                      "Match detail should display Workrate")
        screenshot("05-match-detail")

        // Tap the "Runs" section chip.
        let runsChip = app.buttons["Runs"]
        XCTAssertTrue(runsChip.waitForExistence(timeout: 10), "'Runs' chip should exist")
        runsChip.tap()
        screenshot("06-runs-section")

        // Back to the list.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Matches"].waitForExistence(timeout: 10),
                      "Should navigate back to Matches")
    }

    /// Verifies the Fields and Team tabs render with their distinctive nav titles.
    func testTabsRender() {
        let app = XCUIApplication()
        app.launchArguments += ["-MatchTrackerEntitleTeam"]
        app.launch()

        // Dismiss the launch-time HealthKit authorization sheet before touching the tab bar.
        handleHealthKitPrompt(app: app)

        XCTAssertTrue(app.navigationBars["Matches"].waitForExistence(timeout: 20),
                      "Matches should be the launch tab")

        // Team tab first: it's a Form (the tab bar stays expanded), whereas the Fields map can
        // minimize/obscure the tab bar on iOS 26. selectTab is resilient to both.
        XCTAssertTrue(selectTab("Team", expectingNavBar: "Team", in: app),
                      "Team nav title should appear")
        screenshot("11-team-tab")

        // Fields tab. The map requests location on first appearance — grant it afterward.
        XCTAssertTrue(selectTab("Fields", expectingNavBar: "Fields", in: app),
                      "Fields nav title should appear")
        dismissLocationPromptIfPresent()
        screenshot("10-fields-tab")
    }

    // MARK: - Helpers

    /// Polls `element.exists` up to `timeout`, returning true as soon as it appears. Wraps
    /// `waitForExistence` but tolerates elements that flicker in and out during long async work.
    private func waitForElement(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        return element.exists
    }
}
