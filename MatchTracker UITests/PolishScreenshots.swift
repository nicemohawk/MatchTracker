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

    // NOTE on landscape captures: there is currently no way to run this walk in landscape
    // headlessly. xcodebuild has no destination-orientation knob, TEST_RUNNER_-prefixed env vars
    // don't reach the runner under this scheme, and `XCUIDevice.shared.orientation = .landscapeLeft`
    // (tried pre-launch, post-launch, and post-HealthKit-sheet with a portrait->landscape toggle)
    // rotates the iOS 26 simulator's SCREEN but the app scene never adopts landscape — captures come
    // out sideways with a letterbox band. Landscape review needs a manually rotated simulator.
    func testCaptureNewSurfaces() throws {
        let app = XCUIApplication()
        // -AddFieldSeedCorners: DEBUG hook that auto-places 4 corners in Add Field so the
        // adjust phase (draggable handles) is capturable — synthetic taps don't reach the Map.
        app.launchArguments += ["-hasOnboarded", "YES", "-AddFieldSeedCorners"]
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

        // Reworked matches list: tap a filter chip so the month-grouped list filters down. Prefer
        // "Has GPS" (demo matches carry routes); fall back to the newest year chip. Reset to "All"
        // after so the later match-detail walk starts from the full list.
        let gpsChip = app.buttons["Has GPS"].firstMatch
        let yearChip = app.buttons.matching(
            NSPredicate(format: "label MATCHES %@", "20[0-9]{2}")).firstMatch
        let filterChip = gpsChip.exists ? gpsChip : yearChip
        if filterChip.waitForExistence(timeout: 4) && filterChip.isHittable {
            filterChip.tap()
            sleep(1)
            export("30b-matches-filtered", app: app)
            let allChip = app.buttons["All"].firstMatch
            if allChip.exists && allChip.isHittable { allChip.tap() }
            sleep(1)
        }

        // Team tab: header bar + leaderboard (roster load fails offline → local fallback card).
        _ = selectTab("Team", expectingNavBar: "Team", in: app)
        sleep(2)
        export("31-team-tab", app: app)

        // Fields: a full-bleed map with floating standard controls (no custom drawer). The tab bar
        // stays visible; the trailing control column, bottom-leading list pill, and bottom-trailing
        // Add Field / Scan actions all float clear of it.
        _ = selectTab("Fields", expectingLabelContains: "field", in: app)
        dismissLocationPromptIfPresent(timeout: 5)
        sleep(2)
        export("34-fields-map", app: app)

        // Add Field capsule is always visible in the bottom-trailing action stack.
        let addField = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'add field'")).firstMatch
        if addField.waitForExistence(timeout: 4) && addField.isHittable {
            addField.tap()
            sleep(2)
            export("35-add-field-sheet", app: app)

            // The -AddFieldSeedCorners DEBUG hook auto-places 4 corners ~1.2s after appear,
            // entering the ADJUST phase: pins become draggable handles and the instruction flips
            // to "Drag any corner to fine-tune."
            let adjustHint = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] 'fine-tune'")).firstMatch
            _ = adjustHint.waitForExistence(timeout: 8)
            sleep(1)
            export("35b-add-field-adjust", app: app)

            let cancel = app.buttons["Cancel"]
            if cancel.waitForExistence(timeout: 3) && cancel.isHittable { cancel.tap() }
            sleep(1)
        }

        // List pill → standard fields sheet (detents medium/large). The pill's accessibility label
        // ends in "Open list."; tapping it presents FieldsListSheet with the place-card rows.
        let listPill = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'open list'")).firstMatch
        if listPill.waitForExistence(timeout: 4) && listPill.isHittable {
            listPill.tap()
            sleep(2)
            export("36-fields-list-sheet", app: app)

            // Field detail: each row carries a trailing info button labeled "<name> details" that
            // presents FieldDetailSheet. `isHittable` can THROW for a row near a sheet scroll edge,
            // so probe visibility via frame containment and tap by coordinate.
            let detailButton = app.buttons
                .matching(NSPredicate(format: "label CONTAINS[c] 'Demo Park details'")).firstMatch
            let window = app.windows.firstMatch
            func detailButtonVisible() -> Bool {
                guard detailButton.exists else { return false }
                let frame = detailButton.frame
                guard !frame.isEmpty else { return false }
                return window.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
            }
            if detailButton.waitForExistence(timeout: 4) && detailButtonVisible() {
                detailButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                sleep(2)
                export("36b-field-detail", app: app)
                // Dismiss the detail sheet: its top-leading Cancel, else swipe down.
                let cancel = app.buttons["Cancel"].firstMatch
                if cancel.waitForExistence(timeout: 3) && cancel.isHittable {
                    cancel.tap()
                } else {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                        .press(forDuration: 0.1,
                               thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
                }
                sleep(1)
            }

            // Dismiss the list sheet: its top-trailing Done, else swipe down.
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 3) && done.isHittable {
                done.tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.1,
                           thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            }
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

            // Workrate section: tap its chip and scroll to the new "Match Load" grid (sprint
            // distance, HSR, accel/decel, dist/min, top speed) + acute:chronic load line.
            let workrateChip = app.buttons["Workrate"]
            if workrateChip.waitForExistence(timeout: 4) && workrateChip.isHittable {
                workrateChip.tap()
                sleep(1)
                app.swipeUp(velocity: .slow)
                sleep(1)
                export("32b-workrate-load", app: app)
            }

            // Video section: the sideline-video invite card (import + record entry points).
            // Scroll back up first — the chip row is part of the scroll content and the workrate
            // capture left it off-screen. The Video chip is the last in the horizontally scrolling
            // chip row — drag the row left (anchored on the visible Workrate chip) until hittable.
            for _ in 0..<3 { app.swipeDown(velocity: .fast) }
            sleep(1)
            let videoChip = app.buttons["Video"]
            // NOTE: `isHittable` THROWS ("activation point invalid") for a chip scrolled out of
            // the row's viewport — probe visibility via frame containment instead, and tap by
            // coordinate to bypass the hittability machinery entirely.
            let window = app.windows.firstMatch
            func chipVisible() -> Bool {
                guard videoChip.exists else { return false }
                let frame = videoChip.frame
                guard !frame.isEmpty else { return false }
                return window.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
            }
            var chipDrags = 0
            while !chipVisible() && chipDrags < 3, workrateChip.exists {
                // Drag within the row's interior — an edge-crossing drag becomes the navigation
                // back-swipe and pops the detail screen.
                let rowCenter = workrateChip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                rowCenter.withOffset(CGVector(dx: 220, dy: 0))
                    .press(forDuration: 0.1, thenDragTo: rowCenter.withOffset(CGVector(dx: -160, dy: 0)))
                chipDrags += 1
                usleep(500_000)
            }
            if chipVisible() {
                videoChip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                sleep(1)
                export("32c-video-invite", app: app)
            }

            for _ in 0..<8 { app.swipeUp(velocity: .fast) }
            sleep(1)
            export("33-match-detail-comments", app: app)

            // The video-chip row drags above can trigger the back-swipe and pop the detail view, so
            // each of the two captures below re-opens the match fresh from the list. A freshly opened
            // detail sits on its default Heatmap section with the section-chip row at its start, so
            // the early chips (Heatmap first, Position fourth) are on-screen and hittable. Re-opening
            // scrolls the list to top first — after the earlier walk the list can be scrolled so the
            // first matching row sits off-screen and isn't tappable.
            func reopenMatchDetail() {
                _ = selectTab("Matches", expectingNavBar: "Matches", in: app)
                for _ in 0..<6 { app.swipeDown(velocity: .fast) }
                sleep(1)
                let cell = app.staticTexts
                    .matching(NSPredicate(format: "label CONTAINS 'Demo Park' OR label CONTAINS 'Unknown field'")).firstMatch
                if cell.waitForExistence(timeout: 6) {
                    cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    sleep(3)
                }
            }

            // One fresh detail session covers all three captures. Tap chips by coordinate to bypass
            // the hittability machinery (the section chips live in a horizontally scrolling row).
            reopenMatchDetail()

            // Heatmap section is the default — capture satellite mode FIRST, before selecting the
            // Position chip scrolls the chip row away from the Heatmap chip. Satellite shows the
            // rotated field imagery with the heat cells and full pitch outline overlaid.
            let satellite = app.buttons["Satellite"]
            if satellite.waitForExistence(timeout: 4) {
                satellite.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                sleep(4)   // let the imagery tiles load and the camera settle
                export("32f-heatmap-satellite", app: app)

                // Field-fit diagnostic: the new Route chip overlays the raw GPS polyline on the
                // imagery, so any drift between the fitted field and the real track is visible.
                let routeChip = app.buttons["Route"]
                if routeChip.waitForExistence(timeout: 3) && routeChip.isHittable {
                    routeChip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    sleep(2)
                    export("32f2-heatmap-route", app: app)
                }
            }

            // Field-boundary correction (append-only): from satellite mode, open the corner editor for
            // the resolved field, nudge a corner, save, and confirm the section reprojects end-to-end.
            let adjustField = app.buttons["Adjust Field"]
            if adjustField.waitForExistence(timeout: 4) && adjustField.isHittable {
                adjustField.tap()
                sleep(4)   // the FieldBoundsEditor sheet settles
                // NOTE: the editor is now a large sheet (was a fullScreenCover) with a first-non-zero
                // geometry mount gate, which fixes the white-screen on device. In the simulator's XCUI
                // screenshots an imagery Map can still capture blank, so 32g/32h document the flow
                // reaching the editor and returning; the reprojection itself is verified in code
                // (Save → FieldsModel.save → onFieldsChanged → MatchStore.invalidateForFieldChange →
                // MatchDetailModel.reanalyze) and on-device.
                export("32g-adjust-field", app: app)

                // Nudge a corner handle, then save. Save routes through FieldsModel and fires the
                // reproject pipeline for this match. Coordinate fallback: the blank Metal surface can
                // report the button non-hittable even when the tap lands.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.34, dy: 0.34))
                    .press(forDuration: 0.9,
                           thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.46, dy: 0.46)))
                sleep(1)
                let saveCorrections = app.buttons["Save Corrections"]
                if saveCorrections.waitForExistence(timeout: 4) && saveCorrections.isHittable {
                    saveCorrections.tap()
                } else {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
                }
                sleep(3)   // "Reprojecting…" acknowledgment + section re-render
                export("32h-post-adjust", app: app)
            }

            // Position section: toggle the transparent heatmap underlay ON (32d), then open the
            // multi-select position editor (32e).
            let positionChip = app.buttons["Position"].firstMatch
            if positionChip.waitForExistence(timeout: 4) {
                positionChip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                sleep(1)
                app.swipeUp(velocity: .slow)   // scroll the hero off so the pitch/controls fill the view
                sleep(1)
                let underlay = app.buttons["position-heatmap-underlay"]
                if underlay.waitForExistence(timeout: 3) {
                    underlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    sleep(1)
                }
                export("32d-position", app: app)

                let editChip = app.buttons["position-edit"]
                if editChip.waitForExistence(timeout: 3) {
                    editChip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    sleep(1)
                    app.swipeUp(velocity: .slow)   // reveal the expanded multi-select editor grid
                    sleep(1)
                    export("32e-position-edit", app: app)
                }
            }
        }
    }

    /// Coach dashboard walk: the sideline live view (CoachDashboardView), reached from a toolbar
    /// NavigationLink on Matches that is present only at regular width (iPad) when the team
    /// entitlement is on and a team code is set. Launches entitled, sets a team code, opens the
    /// dashboard, and captures both the Pitch and Timeline detail panes. Offline in the harness, so
    /// these exercise the "waiting for players" / "no events yet" empty states specifically. On a
    /// compact-width device (iPhone) the toolbar link is hidden, so the test skips itself — run it
    /// on an iPad Pro simulator.
    func testCaptureCoachDashboard() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-MatchTrackerEntitleTeam", "-hasOnboarded", "YES"]
        app.launch()
        handleHealthKitPrompt(app: app)
        dismissHealthSyncAlertIfPresent(app: app)

        // The coach toolbar link only appears with a non-empty team code, so set one first.
        if openSettings(app: app) {
            let nameField = app.textFields["Player name"]
            if scrollUntilHittable(nameField, in: app, maxSwipes: 2) {
                clearAndType(nameField, text: "Ben\n", placeholder: "Player name")
            }
            let teamField = app.textFields["Team code"]
            if teamField.exists && teamField.isHittable {
                clearAndType(teamField, text: "TEST01\n", placeholder: "Team code")
            }
        }
        dismissHealthSyncAlertIfPresent(app: app)

        _ = selectTab("Matches", expectingNavBar: "Matches", in: app)

        // Open the coach dashboard from the Matches toolbar (topBarLeading). Its NavigationLink label
        // is a bare `field.of.view.wide` SF Symbol with no explicit accessibility label, so match the
        // symbol name and fall back to the first leading nav-bar button.
        let navButtons = app.navigationBars.buttons
        var coachButton = navButtons.matching(
            NSPredicate(format: "label CONTAINS[c] 'field.of.view' OR label CONTAINS[c] 'field of view'")).firstMatch
        if !coachButton.exists, navButtons.count > 0 {
            coachButton = navButtons.element(boundBy: 0)
        }
        guard coachButton.waitForExistence(timeout: 6) && coachButton.isHittable else {
            throw XCTSkip("Coach dashboard toolbar link absent — hidden at compact width. Run on an iPad simulator.")
        }
        coachButton.tap()

        // The dashboard is a NavigationSplitView; its detail column hosts the Pitch/Timeline picker.
        _ = app.navigationBars["Live Team"].waitForExistence(timeout: 6)
        sleep(3) // let the roster skeletons resolve to the offline "waiting" empty state
        export("39-coach-pitch", app: app)

        // Switch the detail pane to Timeline via the segmented control.
        var timelineSegment = app.segmentedControls.buttons["Timeline"]
        if !timelineSegment.exists { timelineSegment = app.buttons["Timeline"] }
        if timelineSegment.waitForExistence(timeout: 4) && timelineSegment.isHittable {
            timelineSegment.tap()
            sleep(3)
        }
        export("39b-coach-timeline", app: app)
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

    /// Opens the first match whose row label contains `MT_ROW_LABEL` (a coordinator-supplied
    /// substring) and captures its detail — a generic hook for validating one specific match's
    /// analysis end-to-end without hand-driving the simulator.
    func testOpenMatchDetailByLabel() throws {
        guard let needle = ProcessInfo.processInfo.environment["MT_ROW_LABEL"], !needle.isEmpty else {
            throw XCTSkip("Set MT_ROW_LABEL to the row-label substring to open")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-hasOnboarded", "YES"]
        app.launch()
        handleHealthKitPrompt(app: app)
        dismissHealthSyncAlertIfPresent(app: app)

        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", needle)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Row matching '\(needle)' should exist")
        row.tap()
        sleep(6)   // let the lazy analytics + reverse geocode land
        export("99-detail-\(needle.replacingOccurrences(of: " ", with: "-"))", app: app)
        // The hero + metadata header should be up; scroll once to capture the analysis section.
        app.swipeUp()
        sleep(1)
        export("99b-detail-scrolled", app: app)

        // Optionally tap a comma-separated sequence of chips/buttons on the detail (e.g.
        // "Satellite,Adjust Field" — later chips may only exist after earlier ones) and capture
        // what the last one opens.
        if let chips = ProcessInfo.processInfo.environment["MT_TAP_CHIP"], !chips.isEmpty {
            for chip in chips.split(separator: ",").map(String.init) {
                let target = app.buttons[chip].firstMatch
                XCTAssertTrue(target.waitForExistence(timeout: 10), "Chip '\(chip)' should exist")
                target.tap()
                sleep(3)
            }
            sleep(2)
            export("99c-after-chips", app: app)
        }
    }

    /// Deletes one DEMO match end-to-end (context menu → confirmation → gone) and proves the
    /// deletion survives a relaunch. Only ever targets a "Demo Park" row so a run against the
    /// real-history sim can never touch the user's matches; skips where no demo rows exist.
    func testDeleteMatch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasOnboarded", "YES"]
        app.launch()
        handleHealthKitPrompt(app: app)
        dismissHealthSyncAlertIfPresent(app: app)

        let demoRows = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Demo Park'"))
        guard demoRows.firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("No Demo Park rows on this device — nothing safe to delete")
        }
        let victim = demoRows.firstMatch
        // On-screen row counts are useless here — LazyVStack materializes a replacement row as
        // the list shifts — so assert on the top month section's exact aggregate ("N matches · …").
        let headerQuery = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '^[0-9]+ matches.*'")).firstMatch
        XCTAssertTrue(headerQuery.waitForExistence(timeout: 10), "Month header aggregate should exist")
        func headerCount() -> Int {
            Int(headerQuery.label.split(separator: " ").first.map(String.init) ?? "") ?? -1
        }
        let beforeCount = headerCount()
        XCTAssertGreaterThan(beforeCount, 0, "Header aggregate should parse")

        // Preferred path: the card's context menu. Element-anchored `press` is unreliable against
        // SwiftUI context menus in ScrollViews, so press a coordinate inside the card instead.
        victim.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 1.8)
        var deleteItem = app.buttons["Delete Match"]
        if !deleteItem.waitForExistence(timeout: 4) {
            // Automation couldn't summon the menu (a known XCUITest limitation, not a product
            // signal) — exercise the equally-real detail-menu path instead. The press may have
            // pushed the detail already; only navigate if we're still on the list.
            if app.navigationBars["Matches"].exists {
                victim.tap()
            }
            let actionsMenu = app.navigationBars.buttons
                .matching(NSPredicate(format: "label CONTAINS[c] 'more' OR label CONTAINS[c] 'ellipsis'")).firstMatch
            let menuButton = actionsMenu.exists
                ? actionsMenu
                : app.navigationBars.buttons.element(boundBy: app.navigationBars.buttons.count - 1)
            XCTAssertTrue(menuButton.waitForExistence(timeout: 10), "Detail actions menu should exist")
            menuButton.tap()
            deleteItem = app.buttons["Delete Match"]
            XCTAssertTrue(deleteItem.waitForExistence(timeout: 5), "Actions menu should offer Delete Match")
        }
        deleteItem.tap()
        // The dialog re-uses the button title, so an unscoped query can re-resolve to the
        // dismissing menu item and the tap falls outside — cancelling the dialog. Scope to the
        // sheet the confirmationDialog presents as.
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "Confirmation dialog should appear")
        dialog.buttons["Delete Match"].tap()
        sleep(2)
        // If we deleted from the detail view, we've been popped back to the list by dismiss().
        _ = app.navigationBars["Matches"].waitForExistence(timeout: 10)

        XCTAssertEqual(headerCount(), beforeCount - 1,
                       "The month aggregate should drop by one after delete")

        // Relaunch: the deletion must persist (record file removed / workout deleted or hidden).
        app.terminate()
        app.launch()
        XCTAssertTrue(headerQuery.waitForExistence(timeout: 15),
                      "Month header should be back after relaunch")
        sleep(2)
        XCTAssertEqual(headerCount(), beforeCount - 1,
                       "Deleted match must not resurface after relaunch")
    }

    /// Task-specific walk on the REAL imported-history device (never generates demo data, so the
    /// user's history is untouched): proves the persisted summary cache paints the list on a warm
    /// cold-launch, and captures the Compare venue/format/window cohort caption. Run explicitly
    /// against the real-history sim:
    ///   xcodebuild test ... -destination 'id=DFDED7F4-9BBE-4E33-9B24-69032169ABDE' \
    ///     -only-testing:"MatchTracker UITests/PolishScreenshots/testColdLaunchAndCohortCompare"
    func testColdLaunchAndCohortCompare() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasOnboarded", "YES"]

        // A real match card's NavigationLink folds date + field + metrics into one long button label,
        // so a length floor cleanly separates cards from the short filter chips ("All", "Match", …).
        let rowPredicate = NSPredicate(
            format: "label MATCHES %@ AND NOT (label CONTAINS[c] 'Import your history')", ".{24,}")

        // --- First launch: seed the summary cache. This build has never persisted matchSummaries.json,
        // so the list hydrates from HealthKit + records via refresh(), which then writes the snapshot.
        app.launch()
        handleHealthKitPrompt(app: app)
        dismissHealthSyncAlertIfPresent(app: app)
        XCTAssertTrue(app.navigationBars["Matches"].waitForExistence(timeout: 30),
                      "Matches should be the launch surface")
        let firstRow = app.buttons.matching(rowPredicate).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 30),
                      "The real imported history should populate the Matches list")
        sleep(2)   // let refresh() finish writing the summary snapshot before relaunching
        export("30i-matches-real", app: app)

        // --- Warm cold-launch: relaunch with the cache on disk and assert rows are present without an
        // async wait — the list paints from the synchronous snapshot, not after a HealthKit round-trip.
        // Timed from just after launch() returns so process-spawn time is excluded; the snapshot render
        // is what we're measuring.
        app.terminate()
        app.launch()
        let paintStart = Date()
        let warmRow = app.buttons.matching(rowPredicate).firstMatch
        let painted = warmRow.waitForExistence(timeout: 1.5)
        let elapsedMS = Date().timeIntervalSince(paintStart) * 1000
        XCTAssertTrue(painted, "Cached rows should paint within 1.5s of a warm launch")
        add(XCTAttachment(string: String(format: "Warm cold-launch: first row visible %.0f ms after launch()", elapsedMS)))
        export("30j-matches-cold-cache", app: app)

        // --- Build a peer cohort: open several matches so their heatmaps cache (the cohort is drawn
        // from analyzed matches, same as the old season average), then compare one against them.
        openSeveralMatches(app: app, rowPredicate: rowPredicate, target: 8)

        // Back to the list root, scrolled to the top, before opening the match we'll compare.
        _ = app.navigationBars["Matches"].waitForExistence(timeout: 10)
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(openMatchDetail(app: app, rowPredicate: rowPredicate),
                      "Should open a GPS match detail to compare")
        dismissLocationPromptIfPresent(timeout: 4)

        // Heatmap is the default section for a GPS match. Wait for the section chips (detail loaded),
        // then toggle Compare on.
        _ = app.buttons["Workrate"].waitForExistence(timeout: 20)
        let heatmapChip = app.buttons["Heatmap"]
        if heatmapChip.exists && heatmapChip.isHittable { heatmapChip.tap() }
        let compareChip = app.buttons["Compare"]
        XCTAssertTrue(compareChip.waitForExistence(timeout: 15), "Compare chip should exist on the Heatmap section")
        compareChip.tap()

        // The window picker (Season / 90 days / All time) only exists while Compare is on.
        let seasonChip = app.buttons["Season"]
        XCTAssertTrue(seasonChip.waitForExistence(timeout: 8), "Compare window picker should appear while comparing")
        let allTimeChip = app.buttons["All time"]
        if allTimeChip.exists && allTimeChip.isHittable { allTimeChip.tap(); sleep(1) }   // widen for a fuller cohort

        // Honest cohort caption ("vs N matches here · …" / "vs N matches (any field)"), or the empty
        // "Play more matches" line if too few matches were analyzed — record whichever is true.
        let cohortCaption = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'vs '")).firstMatch
        let capHit = cohortCaption.waitForExistence(timeout: 4)
        add(XCTAttachment(string: capHit ? "Cohort caption: \(cohortCaption.label)" : "No cohort caption (too few analyzed)"))
        sleep(1)
        export("32i-compare-cohort", app: app)
    }

    /// Opens distinct match rows one at a time (tap → wait for detail → back), keyed by their button
    /// label so each open is a different match, scrolling when the visible set is exhausted. Warms
    /// each match's cached analytics so the Compare cohort has heatmaps to average.
    private func openSeveralMatches(app: XCUIApplication, rowPredicate: NSPredicate, target: Int) {
        var opened = Set<String>()
        var scrolls = 0
        while opened.count < target && scrolls < target * 3 {
            let rows = app.buttons.matching(rowPredicate)
            var tapped = false
            for index in 0..<rows.count {
                let row = rows.element(boundBy: index)
                guard row.exists, !opened.contains(row.label), row.isHittable else { continue }
                opened.insert(row.label)
                row.tap()
                dismissLocationPromptIfPresent(timeout: 3)
                guard app.buttons["Workrate"].waitForExistence(timeout: 20) else { continue } // opened?
                sleep(1)                                                   // let heatmap analytics cache
                let back = app.navigationBars.buttons.element(boundBy: 0)
                if back.exists && back.isHittable { back.tap() }
                _ = app.navigationBars["Matches"].waitForExistence(timeout: 10)
                tapped = true
                break
            }
            if !tapped { app.swipeUp(velocity: .slow); scrolls += 1 }
        }
    }

    /// Taps the first match card and confirms the detail actually pushed (a NavigationLink tap right
    /// after a scroll animation is occasionally swallowed), retrying up to three times. Verified by
    /// the appearance of the detail's "Workrate" section chip, which the Matches list never shows.
    private func openMatchDetail(app: XCUIApplication, rowPredicate: NSPredicate) -> Bool {
        for _ in 0..<3 {
            let row = app.buttons.matching(rowPredicate).firstMatch
            guard row.waitForExistence(timeout: 10) else { return false }
            row.tap()
            if app.buttons["Workrate"].waitForExistence(timeout: 12) { return true }
            // Tap didn't push (or a prompt intercepted it) — clear any prompt and retry from the top.
            dismissLocationPromptIfPresent(timeout: 2)
            if app.navigationBars["Matches"].exists { app.swipeDown(velocity: .fast) }
        }
        return app.buttons["Workrate"].exists
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
