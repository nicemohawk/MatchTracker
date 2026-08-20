// WatchSmokeTests.swift
// MatchTracker Watch UITests
//
// Headless smoke coverage for the watchOS app: launches it, drives the HealthKit authorization
// sheet if it appears, and verifies the start screen renders — capturing screenshots along the way.
// Elements are located by visible label text / system queries only, no app-side identifiers.

import XCTest

final class WatchSmokeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The watch simulator is slow and the HK sheet paging varies; keep going after a soft
        // failure so we still capture whatever screens ARE reachable.
        continueAfterFailure = true
    }

    /// Launches the watch app, grants HealthKit if prompted, asserts the Start screen renders (the
    /// big "Start Match" button), and captures `60-watch-start`. Then, if reachable, opens Settings
    /// and captures `61-watch-settings`.
    func testStartViewRenders() {
        let app = XCUIApplication()
        app.launch()

        // Capture whatever is on screen right after launch (often the HK sheet on a fresh install).
        screenshot("60a-watch-launch")

        // The watch app calls requestAuthorization() during its launch .task, so a HealthKit sheet
        // (hosted in com.apple.Carousel) may cover the start screen. Drive it if present — this is
        // essential, because the app's Start button stays in the tree behind the sheet, so without
        // dismissing it every screenshot would just show the sheet. Best-effort — see helper docs.
        let drove = handleWatchHealthKitPrompt()
        if drove {
            screenshot("60b-watch-after-hk")
        }

        // The Start screen's primary control is a Label("Start Match", …) inside a Button, under the
        // "MatchTracker" navigation title. Watch launches are slow, so use generous timeouts.
        let startButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Start Match'")).firstMatch
        let navTitle = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] 'MatchTracker'")).firstMatch

        var startVisible = startButton.waitForExistence(timeout: 45)

        // If the sheet was undrivable and still covers the start screen, try dismissing it once more,
        // then re-check. We assert-and-screenshot whatever IS reachable rather than hard-failing.
        if !startVisible {
            _ = handleWatchHealthKitPrompt(timeout: 30)
            if !startButton.waitForExistence(timeout: 10) {
                _ = dismissWatchHealthKitSheet()
            }
            startVisible = startButton.waitForExistence(timeout: 20)
        }

        // Once the start screen renders, its field auto-detect requests location, raising a follow-on
        // system alert (also hosted in Carousel) that sits over the start screen. Grant it and let it
        // dismiss BEFORE capturing the start screenshot, so the shot shows the actual UI.
        handleWatchLocationPrompt(timeout: 10)
        usleep(600_000)

        screenshot("60-watch-start")

        if startVisible {
            XCTAssertTrue(startButton.exists, "Start Match button should be present on the start screen")
        } else {
            // Record what we could see so the run is diagnosable, but don't crash the bundle.
            XCTFail("Start screen did not become reachable — captured 60-watch-start with current state. "
                    + "navTitle exists: \(navTitle.exists). See the HealthKit-sheet limitation notes.")
            return
        }

        // Best-effort: reach Settings via the "Settings" NavigationLink on the start screen and grab
        // a screenshot. It sits below Start/format-picker/field-status/Train-Field, so scroll to it.
        let settingsLink = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Settings'")).firstMatch
        var reachedSettings = settingsLink.waitForExistence(timeout: 5) && settingsLink.isHittable
        var swipes = 0
        while !reachedSettings && swipes < 5 {
            app.swipeUp()
            swipes += 1
            reachedSettings = settingsLink.exists && settingsLink.isHittable
        }

        if reachedSettings {
            settingsLink.tap()
            // Settings pushes onto the NavigationStack; wait for its distinctive nav title.
            let settingsTitle = app.staticTexts.matching(
                NSPredicate(format: "label ==[c] 'Settings'")).firstMatch
            _ = settingsTitle.waitForExistence(timeout: 15)
            screenshot("61-watch-settings")
        } else {
            // Settings not trivially reachable — capture the (scrolled) start screen instead so the
            // slot isn't empty, and note it. Not a failure: the requirement is "if trivially reachable".
            screenshot("61-watch-settings")
        }
    }

    /// Starts a real match (a live HKWorkoutSession on the simulator), walks the in-game pages
    /// (controls / events / metrics) capturing each, then ends the match through the controls page.
    /// Requires HealthKit already granted on this install — run after `testStartViewRenders`
    /// (alphabetical ordering puts this second: "testStartViewRenders" < "testWalkInGamePages"
    /// is false — so drive the HK sheet here too, best-effort).
    func testWalkInGamePages() {
        let app = XCUIApplication()
        app.launch()
        _ = handleWatchHealthKitPrompt(timeout: 15)
        handleWatchLocationPrompt(timeout: 8)

        // Reach the in-game session: normally tap "Start Match", but a prior run may have left an
        // active workout that the app recovers straight into SessionView (which opens on the
        // Metrics page — so there's no Start button and no "Goal" tile, which lives on Events).
        let startButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Start Match'")).firstMatch
        // Metrics-page marker: the "BPM" unit label is present whenever a live session is on screen.
        let metricsMarker = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] 'BPM'")).firstMatch
        if startButton.waitForExistence(timeout: 30) {
            startButton.tap()
        } else if !metricsMarker.waitForExistence(timeout: 8) {
            XCTFail("Neither Start screen nor an in-game page is reachable")
            return
        }

        // The in-game container is a `.verticalPage` TabView, top-to-bottom: Controls, Metrics,
        // Events, opening on Metrics (SessionView.selection = .metrics). NAVIGATION RECIPE — proven
        // empirically: Metrics is the only non-ScrollView page, so it's the reliable pager pivot —
        // one swipe from Metrics pages cleanly (swipeUp → Events below, swipeDown → Controls above).
        // Swipes that ORIGINATE on a ScrollView page (Controls/Events) get absorbed as inner
        // scrolling and don't page, so we always return to Metrics before the next hop, and never
        // rely on a Controls→Metrics swipe. Wait for Metrics to settle first.
        _ = metricsMarker.waitForExistence(timeout: 30)
        sleep(2)

        // ---- 62: Events page (score header + event tiles). swipeUp pages Metrics → Events. ----
        app.swipeUp()
        let flagButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Flag'")).firstMatch
        _ = flagButton.waitForExistence(timeout: 12)
        sleep(1)
        screenshot("62-watch-ingame-events")

        // ---- 63: goal confirmation flash. Reveal the goal grid, tap "Goal Us", grab the flash. ----
        // At the top of Events the "Goal Us" tile only peeks above the fold; one small swipeUp
        // brings the 2×2 grid fully on screen so the button's hit-point is on screen and tappable.
        // The ConfirmationFlash is a full-view overlay, so it's captured regardless of scroll.
        let goalUs = app.buttons.matching(NSPredicate(format: "label ==[c] 'Goal Us'")).firstMatch
        if !(goalUs.exists && goalUs.isHittable) {
            app.swipeUp()
            usleep(500_000)
        }
        if goalUs.waitForExistence(timeout: 8) && goalUs.isHittable {
            goalUs.tap()
        } else {
            // Fallback: tap the Goal Us tile position (top-left of the grid) by coordinate.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.27, dy: 0.5)).tap()
        }
        usleep(400_000)              // inside the ~1s flash window
        screenshot("63-watch-goal-flash")

        // ---- Return to Metrics (the pager pivot). Events may be scrolled, so swipeDown until the
        // Metrics marker reappears: the first swipe scrolls Events to its top, the next pages up. ----
        var hops = 0
        while !metricsMarker.exists && hops < 5 {
            app.swipeDown()
            usleep(700_000)
            hops += 1
        }
        _ = metricsMarker.waitForExistence(timeout: 12)
        sleep(1)

        // ---- 65: Metrics page. Captured here, while parked on the pivot, because a reliable
        // Controls→Metrics swipe doesn't exist (Controls' ScrollView eats the gesture). ----
        screenshot("65-watch-metrics")

        // ---- 64: Controls page (round End/Pause/Lock/Sub buttons). swipeDown pages Metrics →
        // Controls. The tiles carry their titles as sibling captions ("End", "Pause", …). ----
        app.swipeDown()
        let endCaption = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'End'")).firstMatch
        _ = endCaption.waitForExistence(timeout: 12)
        sleep(1)
        screenshot("64-watch-controls")

        // ---- 66: Summary. Tap the round End button (top-left control tile). Its Button wraps only
        // an xmark image, so its label isn't "End"; tap the tile by coordinate, with a label-based
        // fallback. Then wait for the summary's "Done" button and capture. ----
        let endButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'End'")).firstMatch
        if endButton.exists && endButton.isHittable {
            endButton.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.27, dy: 0.30)).tap()
        }

        // A newly-inferred field can raise a save sheet over the summary; dismiss it if present.
        let notNow = app.buttons.matching(NSPredicate(format: "label ==[c] 'Not Now'")).firstMatch
        let done = app.buttons.matching(NSPredicate(format: "label ==[c] 'Done'")).firstMatch
        _ = done.waitForExistence(timeout: 30)
        if notNow.exists && notNow.isHittable {
            notNow.tap()
            _ = done.waitForExistence(timeout: 10)
        }
        sleep(1)
        screenshot("66-watch-summary")
        if done.exists && done.isHittable { done.tap() }
    }

    /// Regression cover for controls that buzz but don't act: taps Pause on the live Controls page
    /// and asserts the tile's caption actually flips to "Resume" (and back), then ends the match
    /// and asserts we leave the live screen. The pause state used to be published only by
    /// HealthKit's delegate callback, so a session that never really started left both controls
    /// looking dead.
    func testPauseResumeAndEndChangeTheUI() {
        let app = XCUIApplication()
        app.launch()
        _ = handleWatchHealthKitPrompt(timeout: 15)
        handleWatchLocationPrompt(timeout: 8)

        let startButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Start Match'")).firstMatch
        let metricsMarker = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] 'BPM'")).firstMatch
        if startButton.waitForExistence(timeout: 45) {
            startButton.tap()
        } else if !metricsMarker.waitForExistence(timeout: 8) {
            XCTFail("Neither Start screen nor an in-game page is reachable")
            return
        }
        _ = metricsMarker.waitForExistence(timeout: 30)
        sleep(2)

        // Metrics → Controls (see the pager recipe in testWalkInGamePages).
        app.swipeDown()
        let pauseCaption = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Pause'")).firstMatch
        let resumeCaption = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Resume'")).firstMatch
        guard pauseCaption.waitForExistence(timeout: 20) else {
            XCTFail("Controls page did not render the Pause tile")
            return
        }

        // The tiles wrap bare SF Symbols, so their Buttons aren't labelled — tap by position
        // (Pause is top-right, End top-left), matching the recipe the other tests use.
        let pauseTile = app.coordinate(withNormalizedOffset: CGVector(dx: 0.73, dy: 0.30))
        pauseTile.tap()
        XCTAssertTrue(resumeCaption.waitForExistence(timeout: 10),
                      "Pause should flip the tile to Resume — a haptic with no state change is the bug")

        pauseTile.tap()
        XCTAssertTrue(pauseCaption.waitForExistence(timeout: 10),
                      "Resume should flip the tile back to Pause")

        // End: this session is well under 30s, so it discards and returns to the start screen.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.27, dy: 0.30)).tap()
        let done = app.buttons.matching(NSPredicate(format: "label ==[c] 'Done'")).firstMatch
        let leftTheLiveScreen = startButton.waitForExistence(timeout: 30) || done.exists
        XCTAssertTrue(leftTheLiveScreen, "End should leave the live session screen")
        if done.exists && done.isHittable { done.tap() }
    }

    /// Opens the touchline-training flow from the start screen, captures its themed idle screen
    /// (`67-watch-train-field`), then backs out. It deliberately never taps "Start Walking", so no
    /// GPS recording is ever started or left running.
    func testTrainFieldCapture() {
        let app = XCUIApplication()
        app.launch()
        _ = handleWatchHealthKitPrompt(timeout: 15)
        handleWatchLocationPrompt(timeout: 8)

        // Reach the start screen; the Train Field link sits below Start/format/field-status.
        let startButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Start Match'")).firstMatch
        guard startButton.waitForExistence(timeout: 45) else {
            XCTFail("Start screen did not become reachable for the Train Field capture")
            return
        }

        let trainLink = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Train Field'")).firstMatch
        var reached = trainLink.waitForExistence(timeout: 5) && trainLink.isHittable
        var swipes = 0
        while !reached && swipes < 5 {
            app.swipeUp()
            swipes += 1
            reached = trainLink.exists && trainLink.isHittable
        }
        guard reached else {
            XCTFail("Train Field link not reachable from the start screen")
            return
        }

        trainLink.tap()
        // The pushed view's nav title is "Train Field"; wait for the "Start Walking" button so we
        // know the idle content (instructions + steps) has rendered before we shoot.
        let startWalking = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Start Walking'")).firstMatch
        _ = startWalking.waitForExistence(timeout: 15)
        sleep(1)
        screenshot("67-watch-train-field")

        // Back out without starting a walk. A left-edge swipe pops the NavigationStack; confirm we
        // land back on the start screen so nothing is left mid-flow.
        app.swipeRight()
        _ = startButton.waitForExistence(timeout: 10)
    }

    /// Enables referee mode via watch Settings, starts a match, captures the referee events page
    /// (`68-watch-referee-events`), logs a yellow card and captures the confirmation flash
    /// (`68b-watch-referee-flash`), ends the (auto-discarded) short session, then turns referee
    /// mode back OFF so the rest of the suite runs in the standard player layout.
    func testRefereeEventsCapture() {
        let app = XCUIApplication()
        app.launch()
        _ = handleWatchHealthKitPrompt(timeout: 15)
        handleWatchLocationPrompt(timeout: 8)

        let startButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Start Match'")).firstMatch
        guard startButton.waitForExistence(timeout: 45) else {
            XCTFail("Start screen did not become reachable for the referee capture")
            return
        }

        // Turn referee mode ON in Settings and VERIFY it engaged — the helper relaunches the app
        // and confirms the start screen's "Referee mode" banner. EventsView reads
        // WatchSettings.refereeMode at render, so this must be verified ON before Start Match.
        guard setRefereeMode(true, app: app) else {
            XCTFail("Referee-mode toggle could not be verified ON — aborting rather than capturing the wrong mode")
            screenshot("68x-referee-toggle-failed")
            _ = setRefereeMode(false, app: app)
            return
        }
        guard startButton.waitForExistence(timeout: 30) else {
            XCTFail("Start screen did not return after enabling referee mode")
            _ = setRefereeMode(false, app: app)
            return
        }

        // ---- Start the match and page Metrics → Events (same recipe as testWalkInGamePages). ----
        startButton.tap()
        let metricsMarker = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] 'BPM'")).firstMatch
        _ = metricsMarker.waitForExistence(timeout: 30)
        sleep(2)

        app.swipeUp()
        // Referee events page marker: the hero "Yellow" card tile. This MUST exist — if it doesn't,
        // the page is showing the wrong (player) layout and capturing it would be misleading.
        let yellow = app.buttons.matching(NSPredicate(format: "label ==[c] 'Yellow'")).firstMatch
        guard yellow.waitForExistence(timeout: 12) else {
            XCTFail("Referee events page did not render the Yellow card tile — wrong layout on screen")
            screenshot("68x-referee-layout-missing")
            _ = setRefereeMode(false, app: app)
            return
        }
        sleep(1)
        screenshot("68-watch-referee-events")

        // ---- 68b: yellow-card confirmation flash. The cards sit at the top of Events, so the tile
        // is on screen; tap it and shoot immediately — the ConfirmationFlash eases out after ~1s. ----
        yellow.tap()
        usleep(300_000)              // early inside the ~1s flash window
        screenshot("68b-watch-referee-flash")

        // ---- Return to Metrics, then page down to Controls and end the match. Sub-30s sessions
        // auto-discard; longer walks land on the summary — both paths are handled below. ----
        var hops = 0
        while !metricsMarker.exists && hops < 5 {
            app.swipeDown()
            usleep(700_000)
            hops += 1
        }
        _ = metricsMarker.waitForExistence(timeout: 12)
        sleep(1)

        app.swipeDown()
        let endCaption = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'End'")).firstMatch
        _ = endCaption.waitForExistence(timeout: 12)
        let endButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'End'")).firstMatch
        if endButton.exists && endButton.isHittable {
            endButton.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.27, dy: 0.30)).tap()
        }

        // Clear any post-match sheet, then finish the summary back to the start screen.
        let notNow = app.buttons.matching(NSPredicate(format: "label ==[c] 'Not Now'")).firstMatch
        let done = app.buttons.matching(NSPredicate(format: "label ==[c] 'Done'")).firstMatch
        _ = done.waitForExistence(timeout: 30)
        if notNow.exists && notNow.isHittable {
            notNow.tap()
            _ = done.waitForExistence(timeout: 10)
        }
        if done.exists && done.isHittable { done.tap() }

        // ---- Cleanup: turn referee mode back OFF so later tests see the standard player layout.
        // Relaunch first so cleanup starts from a known-good start screen even if the summary
        // left us somewhere unexpected. ----
        app.terminate()
        app.launch()
        _ = handleWatchHealthKitPrompt(timeout: 10)
        handleWatchLocationPrompt(timeout: 8)
        _ = startButton.waitForExistence(timeout: 30)
        setRefereeMode(false, app: app)

        // Verify the cleanup stuck: back on the start screen, the "Referee mode" banner must be gone.
        app.terminate()
        app.launch()
        _ = startButton.waitForExistence(timeout: 30)
        let refereeBanner = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'Referee mode'")).firstMatch
        XCTAssertFalse(refereeBanner.exists, "Referee mode should be OFF after cleanup")
    }
}
