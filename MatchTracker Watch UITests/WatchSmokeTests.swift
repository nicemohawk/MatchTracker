// WatchSmokeTests.swift
// MatchTracker Watch UITests
//
// Headless smoke coverage for the watchOS app: launches it, drives the HealthKit authorization
// sheet if it appears, and verifies the start screen renders — capturing screenshots along the way.
// Elements are located by visible label text / system queries only, no app-side identifiers.

import CoreLocation
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
        let metricsMarker = app.descendants(matching: .any).matching(
            NSPredicate(format: "label ==[c] 'Heart rate'")).firstMatch
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
        let flagButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Mark Moment'")).firstMatch
        _ = flagButton.waitForExistence(timeout: 12)
        sleep(1)
        screenshot("62-watch-ingame-events")

        // ---- 63: the goal sheet. Reveal the goal grid, tap "Goal Us", grab the sheet. ----
        // At the top of Events the "Goal Us" tile only peeks above the fold; one small swipeUp
        // brings the 2×2 grid fully on screen so the button's hit-point is on screen and tappable.
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
        let teammate = app.buttons.matching(NSPredicate(format: "label ==[c] 'Teammate'")).firstMatch
        XCTAssertTrue(teammate.waitForExistence(timeout: 5), "Our goal should ask who scored at once")
        screenshot("63-watch-goal")
        teammate.tap()
        sleep(1)

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
        let endCaption = app.buttons.matching(NSPredicate(format: "label ==[c] 'End'")).firstMatch
        _ = endCaption.waitForExistence(timeout: 12)
        sleep(1)
        screenshot("64-watch-controls")

        // ---- 66: Summary. Tap the round End button (top-left control tile). Its Button wraps only
        // an xmark image, so its label isn't "End"; tap the tile by coordinate, with a label-based
        // fallback. Then wait for the summary's "Done" button and capture. ----
        endMatch(app)

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
        let metricsMarker = app.descendants(matching: .any).matching(
            NSPredicate(format: "label ==[c] 'Heart rate'")).firstMatch
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
        let pauseCaption = app.buttons.matching(NSPredicate(format: "label ==[c] 'Pause'")).firstMatch
        guard pauseCaption.waitForExistence(timeout: 20) else {
            XCTFail("Controls page did not render the Pause tile")
            return
        }

        let pauseButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Pause'")).firstMatch
        let resumeButton = app.buttons.matching(NSPredicate(format: "label ==[c] 'Resume'")).firstMatch
        pauseButton.tap()
        XCTAssertTrue(resumeButton.waitForExistence(timeout: 10),
                      "Pause should flip the tile to Resume — a haptic with no state change is the bug")
        resumeButton.tap()
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 10),
                      "Resume should flip the tile back to Pause")

        endMatch(app)
        let done = app.buttons.matching(NSPredicate(format: "label ==[c] 'Done'")).firstMatch
        let leftTheLiveScreen = startButton.waitForExistence(timeout: 30) || done.exists
        XCTAssertTrue(leftTheLiveScreen, "End should leave the live session screen")
        if done.exists && done.isHittable { done.tap() }
    }

    /// The two ways real matches lost their data: the app dying mid-match (a relaunch used to
    /// restart the route from nothing) and tapping Done before the save finished (which used to
    /// save an empty match). Assertions here are UI-level; the saved record is inspected on disk.
    func testMatchSurvivesRelaunchAndEarlyDone() {
        let app = XCUIApplication()
        app.launch()
        _ = handleWatchHealthKitPrompt(timeout: 15)
        handleWatchLocationPrompt(timeout: 8)
        let startButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Start Match'")).firstMatch
        let metricsMarker = app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] 'Heart rate'")).firstMatch
        // A match interrupted minutes ago resumes straight into the live screen instead.
        if startButton.waitForExistence(timeout: 20) { startButton.tap() }
        XCTAssertTrue(metricsMarker.waitForExistence(timeout: 30))
        sleep(20)

        app.terminate()
        app.launch()
        XCTAssertTrue(metricsMarker.waitForExistence(timeout: 45), "A relaunch should land back in the match")
        sleep(20)

        app.swipeDown()
        endMatch(app)
        // Answered and left while it's still saving: the score belongs in the record either way.
        enterScore(app, us: 2, them: 1)
        let save = app.buttons.matching(NSPredicate(format: "label ==[c] 'Save'")).firstMatch
        scroll(app, to: save)
        save.tap()
        tapDone(app)
        XCTAssertTrue(startButton.waitForExistence(timeout: 20))
        sleep(12)
        assertSavedScore(us: 2, them: 1)

        app.terminate()
        app.launch()
        XCTAssertTrue(startButton.waitForExistence(timeout: 45), "A finished match must not come back")
        assertSavedScore(us: 2, them: 1)
    }

    /// Answers "How did it end?" on the summary, short of saving it.
    private func enterScore(_ app: XCUIApplication, us: Int, them: Int) {
        for (side, goals) in [("Us", us), ("Them", them)] {
            let tile = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "\(side), goals")).firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 20), "A match with no goals logged should ask the score at once")
            scroll(app, to: tile)
            for _ in 0..<goals { tile.tap() }
            XCTAssertEqual(tile.value as? String, "\(goals)")
        }
    }

    /// Scrolls a little at a time, letting the list come to rest before anything is tapped.
    private func scroll(_ app: XCUIApplication, to element: XCUIElement) {
        sleep(1)
        for _ in 0..<12 where !(element.exists && element.isHittable && element.frame.maxY < app.frame.maxY - 8) {
            XCUIDevice.shared.rotateDigitalCrown(delta: 0.25)
            usleep(500_000)
        }
    }

    private func tapDone(_ app: XCUIApplication) {
        let done = app.buttons.matching(NSPredicate(format: "label ==[c] 'Done'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 20), "End should show the summary at once")
        scroll(app, to: done)
        done.tap()
    }

    /// The newest finished record in the app group. Simulators share one file system, and no paired
    /// phone has collected it.
    private func newestRecord() -> [String: Any]? {
        let groups = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("../../../Shared/AppGroup").standardizedFileURL
        let records = FileManager.default.enumerator(at: groups, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "json" && $0.deletingLastPathComponent().lastPathComponent == "matches" } ?? []
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let newest = records.max { modified($0) < modified($1) }.flatMap { try? Data(contentsOf: $0) }
        return newest.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }

    private func assertSavedScore(us: Int, them: Int, line: UInt = #line) {
        let score = newestRecord()?["finalScore"] as? [String: Int]
        XCTAssertEqual(score, ["us": us, "them": them, "mine": 0], line: line)
    }

    /// An unnoticed pause in the first seconds must not make the whole match look accidental.
    func testEarlyPauseDoesNotDiscardTheMatch() {
        let app = XCUIApplication()
        app.launch()
        _ = handleWatchHealthKitPrompt(timeout: 10)
        handleWatchLocationPrompt(timeout: 5)
        let startButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Start Match'")).firstMatch
        let heartRate = app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] 'Heart rate'")).firstMatch
        XCTAssertTrue(startButton.waitForExistence(timeout: 40))
        startButton.tap()
        XCTAssertTrue(heartRate.waitForExistence(timeout: 20))
        sleep(1)
        app.swipeDown()
        let pause = app.buttons.matching(NSPredicate(format: "label ==[c] 'Pause'")).firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.tap()
        sleep(35)
        endMatch(app)
        let done = app.buttons.matching(NSPredicate(format: "label ==[c] 'Done'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 20), "A 40-second match that was mostly paused is still a match")

        // Goals tapped in are an answer, even if Done is what gets tapped next.
        enterScore(app, us: 0, them: 1)
        tapDone(app)
        XCTAssertTrue(startButton.waitForExistence(timeout: 20))
        sleep(8)
        assertSavedScore(us: 0, them: 1)
    }

    private static let pitch = CLLocation(latitude: 40.02, longitude: -83.02)

    /// Moves the watch about the pitch, or along a straight road away from it, a fix a second.
    /// - Returns: How far along the road it ended up.
    @discardableResult
    private func move(for seconds: Int, from meters: Double = 0, speed: Double, until: () -> Bool = { false }) -> Double {
        var meters = meters
        let began = Date()
        for second in 0..<seconds {
            if until() { break }
            let isOnTheRoad = abs(speed) >= 7
            if isOnTheRoad { meters = max(0, meters + speed) }
            let angle = Double(second) / 8
            let north = isOnTheRoad ? 0 : 20 * sin(angle), east = isOnTheRoad ? meters : meters + 20 * cos(angle)
            XCUIDevice.shared.location = XCUILocation(location: CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: Self.pitch.coordinate.latitude + north / 111_320,
                    longitude: Self.pitch.coordinate.longitude + east / (111_320 * cos(Self.pitch.coordinate.latitude * .pi / 180))),
                altitude: 200, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: abs(speed), timestamp: Date()))
            let wait = began.addingTimeInterval(Double(second + 1)).timeIntervalSinceNow
            if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
        }
        return meters
    }

    private func startMatchAtThePitch() -> XCUIApplication {
        move(for: 2, speed: 2.6)
        let app = XCUIApplication()
        app.launch()
        _ = handleWatchHealthKitPrompt(timeout: 10)
        handleWatchLocationPrompt(timeout: 5)
        let startButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Start Match'")).firstMatch
        XCTAssertTrue(startButton.waitForExistence(timeout: 40))
        startButton.tap()
        return app
    }

    /// Asked as soon as the watch drives off; ending from the question ends when play did.
    func testDrivingOffEndsAtThePitch() throws {
        let app = startMatchAtThePitch()
        let kickoff = Date()
        move(for: 330, speed: 2.6)
        let left = Date()
        let question = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "You've left the pitch")).firstMatch
        move(for: 200, speed: 12) { question.exists }
        XCTAssertTrue(question.exists, "Driving off should ask at once")
        sleep(2)
        screenshot("70-left")
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'End Match'")).firstMatch.tap()
        sleep(40)
        screenshot("71-left-summary")
        try assertSavedMatch(endsWithin: 75, of: left, after: kickoff, farthestMeters: 300)
        tapDone(app)
    }

    /// Nipping off mid-match asks once, forgets about it on the way back, and loses nothing. Ended
    /// by hand on the way home, the match ends at the pitch.
    func testDrivingAwayAndBackKeepsTheMatch() throws {
        let app = startMatchAtThePitch()
        let kickoff = Date()
        let heartRate = app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] 'Heart rate'")).firstMatch
        let question = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "You've left the pitch")).firstMatch
        move(for: 100, speed: 2.6)
        let away = move(for: 200, speed: 12) { question.exists }
        XCTAssertTrue(question.exists, "Driving off should ask at once")
        move(for: Int(away / 12) + 1, from: away, speed: -12)
        move(for: 90, speed: 2.6) { heartRate.exists }
        XCTAssertTrue(heartRate.exists, "Coming back should withdraw the question")
        move(for: 180, speed: 2.6)
        let left = Date()
        move(for: 110, speed: 12)
        XCTAssertFalse(question.exists, "Asked once already, minutes ago")
        app.swipeDown()
        endMatch(app)
        sleep(40)
        screenshot("72-left-by-hand")
        try assertSavedMatch(endsWithin: 75, of: left, after: kickoff, farthestMeters: 10_000)
        tapDone(app)
    }

    private func assertSavedMatch(endsWithin seconds: TimeInterval, of end: Date, after start: Date,
                                  farthestMeters: Double, line: UInt = #line) throws {
        let record = try XCTUnwrap(newestRecord(), line: line)
        let dates = ISO8601DateFormatter()
        let savedEnd = try XCTUnwrap((record["endDate"] as? String).flatMap(dates.date(from:)), line: line)
        let savedStart = try XCTUnwrap((record["startDate"] as? String).flatMap(dates.date(from:)), line: line)
        XCTAssertEqual(savedStart.timeIntervalSince(start), 0, accuracy: 15, line: line)
        XCTAssertEqual(savedEnd.timeIntervalSince(end), 0, accuracy: seconds, line: line)
        let track = try XCTUnwrap(record["track"] as? [[String: Any]], line: line)
        let farthest = track.compactMap { $0["coordinate"] as? [String: Double] }
            .compactMap { point in
                point["latitude"].flatMap { latitude in
                    point["longitude"].map { CLLocation(latitude: latitude, longitude: $0).distance(from: Self.pitch) }
                }
            }.max()
        XCTAssertLessThan(try XCTUnwrap(farthest, line: line), farthestMeters, line: line)
        XCTAssertGreaterThan(Double(track.count), 0.8 * savedEnd.timeIntervalSince(savedStart), "the route is whole", line: line)
    }

    /// Nobody counting: no score anywhere, and the wearer's own goals one tap away.
    func testAMatchWithoutScore() {
        let app = XCUIApplication()
        app.launchArguments = ["-formatsWithoutScore", "(match)"]
        app.launch()
        _ = handleWatchHealthKitPrompt(timeout: 10)
        handleWatchLocationPrompt(timeout: 5)
        let startButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Start Match'")).firstMatch
        let heartRate = app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] 'Heart rate'")).firstMatch
        XCTAssertTrue(startButton.waitForExistence(timeout: 40))
        startButton.tap()
        XCTAssertTrue(heartRate.waitForExistence(timeout: 20))
        sleep(32)
        app.swipeUp()
        let scored = app.buttons.matching(NSPredicate(format: "label ==[c] 'I scored'")).firstMatch
        XCTAssertTrue(scored.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label ==[c] 'Goal Them'")).firstMatch.exists)
        screenshot("73-no-score")
        scored.tap()
        usleep(500_000)
        screenshot("74-no-score-goal")
        sleep(3)
        for _ in 0..<4 where !heartRate.exists { app.swipeDown(); usleep(700_000) }
        screenshot("75-no-score-glance")
        app.swipeDown()
        app.buttons.matching(NSPredicate(format: "label ==[c] 'Sub Out'")).firstMatch.tap()
        sleep(1)
        app.swipeUp()
        sleep(1)
        app.swipeUp()
        sleep(1)
        screenshot("76-no-score-bench")
        app.swipeDown()
        sleep(1)
        app.swipeDown()
        sleep(1)
        endMatch(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label ==[c] 'Done'")).firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'How did it end?'")).firstMatch.exists)
        sleep(6)
        screenshot("77-no-score-summary")
        tapDone(app)
        XCTAssertEqual(newestRecord()?["keepsScore"] as? Bool, false)
    }

    /// Captures every redesigned screen of a real match, for design review.
    func testCaptureMatchDesign() {
        let app = XCUIApplication()
        app.launch()
        _ = handleWatchHealthKitPrompt(timeout: 10)
        handleWatchLocationPrompt(timeout: 5)
        let startButton = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Start Match'")).firstMatch
        let heartRate = app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] 'Heart rate'")).firstMatch
        XCTAssertTrue(startButton.waitForExistence(timeout: 40))
        sleep(3)
        screenshot("80-start")
        startButton.tap()
        usleep(900_000)
        screenshot("81-countdown")
        XCTAssertTrue(heartRate.waitForExistence(timeout: 20))
        sleep(6)
        screenshot("82-live")
        app.swipeUp()
        sleep(1)
        screenshot("83-score")
        app.buttons.matching(NSPredicate(format: "label ==[c] 'Goal Us'")).firstMatch.tap()
        let scored = app.buttons.matching(NSPredicate(format: "label ==[c] 'I scored'")).firstMatch
        XCTAssertTrue(scored.waitForExistence(timeout: 5))
        sleep(1)
        screenshot("84-goal")
        app.swipeUp()
        sleep(1)
        screenshot("84b-goal-undo")
        app.buttons.matching(NSPredicate(format: "label ==[c] 'Undo'")).firstMatch.tap()
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label ==[c] 'Goal Us'")).firstMatch.tap()
        XCTAssertTrue(scored.waitForExistence(timeout: 5))
        sleep(1)
        scored.tap()
        sleep(1)
        app.buttons.matching(NSPredicate(format: "label ==[c] 'Goal Them'")).firstMatch.tap()
        usleep(600_000)
        screenshot("85-goal-them")
        sleep(5)
        for _ in 0..<4 where !heartRate.exists { app.swipeDown(); usleep(700_000) }
        screenshot("86-live-score")
        app.swipeDown()
        sleep(1)
        screenshot("87-controls")
        app.buttons.matching(NSPredicate(format: "label ==[c] 'Sub Out'")).firstMatch.tap()
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        sleep(2)
        screenshot("88-bench")
        sleep(14)
        app.swipeDown()
        sleep(1)
        screenshot("88b-back-on")
        // Back on, and take both goals back: the summary then has to ask.
        app.buttons.matching(NSPredicate(format: "label ==[c] 'Back On'")).firstMatch.tap()
        for _ in 0..<4 where !heartRate.exists { app.swipeUp(); usleep(700_000) }
        app.swipeUp()
        sleep(1)
        let takeBack = app.buttons.matching(NSPredicate(format: "label ==[c] 'Take Back Last Goal'")).firstMatch
        for goal in 1...2 {
            scroll(app, to: takeBack)
            screenshot("88c-take-back-\(goal)")
            takeBack.tap()
            sleep(1)
            screenshot("88d-take-back-confirm-\(goal)")
            app.buttons.matching(NSPredicate(format: "label ==[c] 'Take Back'")).firstMatch.tap()
            sleep(1)
        }
        for _ in 0..<4 where !heartRate.exists { app.swipeDown(); usleep(700_000) }
        app.swipeDown()
        sleep(1)
        let end = app.buttons.matching(NSPredicate(format: "label ==[c] 'End'")).firstMatch
        _ = end.waitForExistence(timeout: 8)
        end.tap()
        sleep(1)
        screenshot("89-confirm")
        app.buttons.matching(NSPredicate(format: "label ==[c] 'End Match'")).firstMatch.tap()
        sleep(1)
        screenshot("90-summary-saving")
        sleep(6)
        screenshot("91-summary-score")
        enterScore(app, us: 2, them: 1)
        screenshot("92-summary-score-entered")
        let save = app.buttons.matching(NSPredicate(format: "label ==[c] 'Save'")).firstMatch
        scroll(app, to: save)
        screenshot("92b-summary-save")
        save.tap()
        sleep(1)
        app.swipeDown()
        sleep(3)
        screenshot("93-summary")
        for page in 1...4 {
            app.swipeUp()
            sleep(1)
            screenshot("94-summary-\(page)")
        }
    }

    /// Taps End on the Controls page and confirms.
    private func endMatch(_ app: XCUIApplication) {
        let end = app.buttons.matching(NSPredicate(format: "label ==[c] 'End'")).firstMatch
        if end.waitForExistence(timeout: 12) { end.tap() }
        let confirm = app.buttons.matching(NSPredicate(format: "label ==[c] 'End Match'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "End should ask first")
        confirm.tap()
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
        let metricsMarker = app.descendants(matching: .any).matching(
            NSPredicate(format: "label ==[c] 'Heart rate'")).firstMatch
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
        let endCaption = app.buttons.matching(NSPredicate(format: "label ==[c] 'End'")).firstMatch
        _ = endCaption.waitForExistence(timeout: 12)
        endMatch(app)

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
