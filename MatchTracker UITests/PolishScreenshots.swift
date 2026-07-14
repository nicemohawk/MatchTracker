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
                clearAndType(nameField, text: "Ben\n", placeholder: "Player name")
            }
            let teamField = app.textFields["Team code"]
            if teamField.exists && teamField.isHittable {
                // Clear first — the team code accumulated across reinstall-per-run invocations.
                clearAndType(teamField, text: "TEST01\n", placeholder: "Team code")
            }
            // \n dismisses the keyboard so the rows below are hittable again.
            // Generate a season so the list and detail screens have real content.
            let generate = app.buttons["Generate Sample Season (5)"]
            if scrollUntilHittable(generate, in: app) {
                generate.tap()
                // Writing the synthetic workouts to HealthKit can raise a second authorization sheet
                // (on iPad the write scopes prompt separately from the launch read prompt). Handle it
                // so generation isn't stuck behind it. Best-effort: a no-op where no sheet appears.
                handleHealthKitPrompt(app: app, timeout: 8)
                _ = app.staticTexts
                    .matching(NSPredicate(format: "label BEGINSWITH 'Generated sample season'"))
                    .firstMatch.waitForExistence(timeout: 120)
            }
            // Capture the settings form itself (at regular width it should read as a centered,
            // readable column, not a full-bleed grouped list).
            app.swipeDown(velocity: .fast) // scroll the form back to the top for the shot
            export("38-settings", app: app)
            // Settings is a tab (role: .search) now, not a sheet — leaving it = switching tabs.
        }

        // A fresh iPad (iCloud Health sync off) raises a blocking "iCloud Health Data Sync is Off"
        // card after HealthKit authorization that sits over every screen; dismiss it so the walk
        // isn't stuck behind it. Best-effort and harmless where it never appears (e.g. iPhone).
        dismissHealthSyncAlertIfPresent(app: app)

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

        // Drawer expanded state: the drawer is a custom floating card whose grabber/summary header
        // is the only drag target (FieldsDrawer.swift). Anchor the drag to the summary text (the
        // hint line, or the "· nearest …" subtitle) rather than a magic coordinate, since the peek
        // card floats above the tab bar at a height that varies with the device. Drag it up to the
        // half snap to reveal the actions row and field list, then drag back down to the peek.
        let drawerHandle = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] 'Swipe up to browse' OR label CONTAINS[c] 'nearest'")).firstMatch
        if drawerHandle.waitForExistence(timeout: 4) {
            let raisedTarget = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40))
            drawerHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.2, thenDragTo: raisedTarget)
            sleep(1)
            export("36-fields-drawer-expanded", app: app)
            // Drag the header (now near mid-screen) back down to collapse to the peek snap.
            drawerHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.2,
                       thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
            sleep(1)
        }

        // Match detail: open the newest match and walk to the bottom (comments section).
        _ = selectTab("Matches", expectingNavBar: "Matches", in: app)
        let row = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS 'Demo Park' OR label CONTAINS 'Unknown field'")).firstMatch
        if row.waitForExistence(timeout: 10) {
            row.tap()
            sleep(3)
            export("32-match-detail-top", app: app)

            // Export/share menu: a single top-bar-trailing Menu (MatchDetailView.swift) whose label
            // is an `square.and.arrow.up` glyph. Opening it reveals Re-upload / Export… / team-tag
            // items. The button carries no explicit accessibility label, so match the SF Symbol name
            // and fall back to the last nav-bar button.
            let navButtons = app.navigationBars.buttons
            var shareButton = navButtons
                .matching(NSPredicate(format: "label CONTAINS[c] 'square.and.arrow' OR label CONTAINS[c] 'share' OR label CONTAINS[c] 'export' OR label CONTAINS[c] 'more'")).firstMatch
            if !shareButton.exists, navButtons.count > 0 {
                shareButton = navButtons.element(boundBy: navButtons.count - 1)
            }
            if shareButton.exists && shareButton.isHittable {
                shareButton.tap()
                sleep(1)
                export("37-export-menu", app: app)
                // Dismiss the menu by tapping the dimmed backdrop away from the anchored items.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.85)).tap()
                sleep(1)
            }

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

    /// Dismisses the "iCloud Health Data Sync is Off" card (Not Now) if it is on screen. It can be
    /// presented as an in-app card or a system alert, so both the app's own tree and Springboard are
    /// checked. Best-effort: returns quietly when no such card exists.
    private func dismissHealthSyncAlertIfPresent(app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            for host in [app, springboard] {
                let notNow = host.buttons["Not Now"]
                if notNow.exists && notNow.isHittable {
                    notNow.tap()
                    return
                }
            }
            usleep(300_000)
        }
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
