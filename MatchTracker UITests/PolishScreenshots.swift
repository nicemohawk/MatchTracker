// PolishScreenshots.swift
// MatchTracker UITests
//
// Not a smoke test: a screenshot walk over the newest surfaces (Team leaderboard, match-detail
// comments) exporting PNGs for design review. Excluded from CI intent by name; run explicitly:
//   xcodebuild test ... -only-testing:"MatchTracker UITests/PolishScreenshots" \
//     TEST_RUNNER_SHOT_DIR=/path/to/output
// Writes are best-effort — without SHOT_DIR, shots still land as .keepAlways attachments.

import XCTest

final class PolishScreenshots: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testCaptureNewSurfaces() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasOnboarded", "YES"]
        app.launch()
        handleHealthKitPrompt(app: app)

        // Configure identity so team-gated surfaces (comments, team header) render.
        if openSettings(app: app) {
            let nameField = app.textFields["Player name"]
            if scrollUntilHittable(nameField, in: app, maxSwipes: 2) {
                nameField.tap()
                nameField.typeText("Ben\n")
            }
            let teamField = app.textFields["Team code"]
            if teamField.exists && teamField.isHittable {
                teamField.tap()
                teamField.typeText("TEST01\n")
            }
            // \n dismisses the keyboard so the rows below are hittable again.
            // Generate a season so the list and detail screens have real content.
            let generate = app.buttons["Generate Sample Season (5)"]
            if scrollUntilHittable(generate, in: app) {
                generate.tap()
                _ = app.staticTexts
                    .matching(NSPredicate(format: "label BEGINSWITH 'Generated sample season'"))
                    .firstMatch.waitForExistence(timeout: 120)
            }
            // Settings is a tab (role: .search) now, not a sheet — leaving it = switching tabs.
        }

        _ = selectTab("Matches", expectingNavBar: "Matches", in: app)
        export("30-matches", app: app)

        // Team tab: header bar + leaderboard (roster load fails offline → local fallback card).
        _ = selectTab("Team", expectingNavBar: "Team", in: app)
        sleep(2)
        export("31-team-tab", app: app)

        // Fields: the custom drawer must leave the tab bar visible (user-reported regression).
        _ = selectTab("Fields", expectingNavBar: "Fields", in: app)
        dismissLocationPromptIfPresent(timeout: 5)
        sleep(2)
        export("34-fields-drawer", app: app)
        let addField = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'add field' OR label == 'Add'")).firstMatch
        if addField.waitForExistence(timeout: 4) && addField.isHittable {
            addField.tap()
            sleep(2)
            export("35-add-field-sheet", app: app)
            let cancel = app.buttons["Cancel"]
            if cancel.exists && cancel.isHittable { cancel.tap() }
        }

        // Match detail: open the newest match and walk to the bottom (comments section).
        _ = selectTab("Matches", expectingNavBar: "Matches", in: app)
        let row = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Demo Park' OR label CONTAINS 'Unknown field'")).firstMatch
        if row.waitForExistence(timeout: 10) {
            row.tap()
            sleep(3)
            export("32-match-detail-top", app: app)
            for _ in 0..<8 { app.swipeUp(velocity: .fast) }
            sleep(1)
            export("33-match-detail-comments", app: app)
        }
    }

    /// Onboarding walk: launched WITHOUT the -hasOnboarded seed, the per-run reinstall means the
    /// first-run cover shows. Captures each page, then drives through so the session ends clean.
    func testCaptureOnboarding() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(2)
        export("40-onboarding-1", app: app)
        let primary = app.buttons["Continue"]
        if primary.waitForExistence(timeout: 6) {
            primary.tap(); sleep(1)
            export("41-onboarding-2", app: app)
            if primary.exists { primary.tap(); sleep(1) }
            export("42-onboarding-3", app: app)
        }
        // Leave via Skip (Health access is exercised by the smoke test's sheet driver).
        let skip = app.buttons["Skip"]
        if skip.exists && skip.isHittable { skip.tap() }
        handleHealthKitPrompt(app: app, timeout: 8)
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 8)
    }

    /// Saves a PNG to $SHOT_DIR (runner env, host-visible path) and always attaches to the result.
    private func export(_ name: String, app: XCUIApplication) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
