// DesignCapture.swift
// MatchTracker UITests
//
// Walks the app's main screens for design review. Run against a simulator that already has matches.

import XCTest

final class DesignCapture: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-hasOnboarded", "YES"]
        app.launchArguments += ProcessInfo.processInfo.environment["APP_ARGUMENTS"]?.split(separator: " ").map(String.init) ?? []
    }

    func testGrantHealth() {
        app.launch()
        for _ in 0..<2 { handleHealthKitPrompt(app: app) }
    }

    func testImportArchive() {
        app.launchArguments += ["-ImportDiagnostics", "YES"]
        app.launch()
        for _ in 0..<3 { handleHealthKitPrompt(app: app) }
        sleep(100)
        screenshot("00-imported")
    }

    func testWalk() {
        app.launch()
        handleHealthKitPrompt(app: app, timeout: 4)
        sleep(10)
        screenshot("01-summary")
        app.swipeUp()
        sleep(1)
        screenshot("02-summary-2")
        app.swipeUp()
        sleep(1)
        screenshot("03-summary-3")
        // The bar minimizes on the way down and comes back on the way up.
        for _ in 0..<3 { app.swipeDown() }
        sleep(1)
        app.tabBars.buttons["Matches"].tap()
        sleep(3)
        screenshot("04-matches")
        let row = app.collectionViews.cells.element(boundBy: ProcessInfo.processInfo.environment["ROW"].flatMap(Int.init) ?? 3)
        if row.waitForExistence(timeout: 5) { row.tap() }
        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 15), "A row should open its match")
        sleep(5)
        screenshot("05-match")
        if app.buttons["Runs"].exists { app.buttons["Runs"].tap(); sleep(1); screenshot("06-match-runs") }
        if app.buttons["Season"].exists { app.buttons["Season"].tap(); sleep(1); screenshot("07-match-season") }
        if app.segmentedControls.buttons["Match"].exists { app.segmentedControls.buttons["Match"].tap() }
        if app.buttons["Play"].exists { app.buttons["Play"].tap(); sleep(6); screenshot("08-match-playing") }
        app.swipeUp()
        sleep(1)
        screenshot("09-match-2")
        app.swipeUp()
        sleep(1)
        screenshot("10-match-3")
        if app.buttons["All numbers"].exists { app.buttons["All numbers"].tap(); sleep(1); screenshot("11-numbers"); app.navigationBars.buttons.element(boundBy: 0).tap() }
        sleep(1)
        if app.buttons["More"].exists {
            app.buttons["More"].tap()
            sleep(1)
            if app.buttons["Edit Match"].exists { app.buttons["Edit Match"].tap() }
            sleep(2)
            screenshot("12-edit")
            app.swipeUp()
            sleep(1)
            screenshot("13-edit-2")
        }
    }

    /// The match screen: opening, playing, and every way of sending a minute to the picture.
    func testStage() {
        openMatch()
        sleep(9)
        screenshot("50-match")
        // Large type puts the controls under the tab bar until they're scrolled to.
        if app.buttons["Play"].frame.maxY > app.frame.maxY - 110 { app.swipeUp(velocity: .slow) }
        app.buttons["Play"].tap()
        sleep(5)
        screenshot("51-playing")
        app.buttons["Pause"].tap()
        app.sliders["Match time"].adjust(toNormalizedSliderPosition: 0.5)
        sleep(1)
        screenshot("52-scrubbed")
        app.buttons["Whole Match"].tap()
        sleep(1)
        XCTAssertFalse(app.sliders["Match time"].exists, "The slider is only there while there's a time to show")
        if app.buttons["Runs"].exists {
            app.buttons["Runs"].tap()
            sleep(2)
            screenshot("53-runs")
        }
        if app.buttons["Season"].exists {
            app.buttons["Season"].tap()
            sleep(2)
            XCTAssertFalse(app.buttons["Play"].exists, "A season doesn't play")
            screenshot("54-season")
        }
        tapRow(saying: " over ")
        sleep(3)
        screenshot("55-run")
        sleep(10)
        screenshot("56-run-finished")
        tapRow(saying: "Minute", "goal", "Goal", "scored", "assist", "Flagged")
        sleep(3)
        screenshot("57-moment")
        sleep(8)
        screenshot("58-moment-finished")
        for _ in 0..<3 { app.swipeUp() }
        sleep(1)
        screenshot("59-effort")
    }

    /// A match nobody has opened on this simulator: touching it ends its opening, and still scrolls.
    func testStageOpening() {
        openMatch()
        screenshot("60-opening")
        app.swipeUp(velocity: .slow)
        sleep(1)
        screenshot("61-touched")
        app.swipeDown()
        app.swipeDown()
        sleep(1)
        screenshot("62-settled")
    }

    private func openMatch() {
        app.launch()
        handleHealthKitPrompt(app: app, timeout: 4)
        sleep(6)
        app.buttons["Matches"].firstMatch.tap()
        sleep(2)
        let day = ProcessInfo.processInfo.environment["DAY"] ?? "Jul 14"
        let row = app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@", day)).firstMatch
        for _ in 0..<12 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 15), "A match with a route should play")
    }

    private func tapRow(saying words: String...) {
        let saysOne = NSCompoundPredicate(orPredicateWithSubpredicates: words.dropFirst(words.count > 1 ? 1 : 0).map {
            NSPredicate(format: "label CONTAINS %@", $0)
        })
        let row = app.buttons.matching(NSCompoundPredicate(andPredicateWithSubpredicates: [
            saysOne, NSPredicate(format: "label CONTAINS %@", words[0])
        ])).firstMatch
        for _ in 0..<5 where !row.exists || !row.isHittable { app.swipeUp() }
        if row.exists { row.tap() }
    }

    func testVideo() {
        app.launch()
        handleHealthKitPrompt(app: app, timeout: 4)
        sleep(8)
        app.tabBars.buttons["Matches"].tap()
        let row = app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS 'Jul 14'")).firstMatch
        for _ in 0..<12 where !row.isHittable { app.swipeUp() }
        row.tap()
        sleep(5)
        app.swipeUp()
        sleep(2)
        screenshot("20-moments")
        app.buttons["More"].tap()
        app.buttons["Video"].tap()
        sleep(3)
        screenshot("21-video")
        app.collectionViews.cells.element(boundBy: 1).tap()
        sleep(4)
        screenshot("22-clip")
        app.buttons["Done"].firstMatch.tap()
        sleep(1)
        for _ in 0..<3 { app.swipeUp() }
        app.buttons["Line Up with the Match"].tap()
        sleep(3)
        screenshot("23-line-up")
    }

    func testEffort() {
        for pass in 1...2 {
            app.launch()
            handleHealthKitPrompt(app: app, timeout: 4)
            sleep(8)
            app.tabBars.buttons["Matches"].tap()
            app.collectionViews.cells.element(boundBy: 3).tap()
            sleep(4)
            let rate = app.buttons["Rate your effort"].firstMatch
            for _ in 0..<5 { app.swipeUp() }
            sleep(1)
            screenshot("30-effort-\(pass)")
            if rate.exists {
                rate.tap()
                sleep(1)
                app.sliders["Effort"].adjust(toNormalizedSliderPosition: 0.8)
                screenshot("31-rating-\(pass)")
                app.buttons["Save"].tap()
                handleHealthKitPrompt(app: app, timeout: 6)
                sleep(3)
                screenshot("32-rated-\(pass)")
            }
            app.terminate()
        }
    }

    /// The iPad's Health sheet is a centered form whose controls don't report as hittable.
    func testPadGrantHealth() {
        app.launchArguments += ["-ImportDiagnostics", "YES"]
        app.launch()
        for pass in 0..<2 {
            sleep(8)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.557)).tap()
            sleep(2)
            screenshot("0\(pass)-on")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.664)).tap()
            sleep(2)
            screenshot("0\(pass)-allowed")
        }
        sleep(90)
        screenshot("00-granted")
    }

    func testPad() {
        app.launch()
        sleep(6)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.557)).tap()
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.664)).tap()
        sleep(8)
        screenshot("40-pad-summary")
        app.buttons["Matches"].firstMatch.tap()
        sleep(3)
        screenshot("41-pad-matches")
        app.collectionViews.cells.element(boundBy: 3).tap()
        sleep(6)
        screenshot("42-pad-match")
        app.buttons["Team"].firstMatch.tap()
        sleep(2)
        screenshot("43-pad-team")
        XCUIDevice.shared.orientation = .landscapeLeft
        app.buttons["Matches"].firstMatch.tap()
        sleep(3)
        screenshot("44-pad-landscape")
        app.buttons["Summary"].firstMatch.tap()
        sleep(2)
        screenshot("45-pad-summary-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    func testIndoor() {
        app.launch()
        handleHealthKitPrompt(app: app, timeout: 4)
        sleep(8)
        app.tabBars.buttons["Matches"].tap()
        sleep(2)
        let row = app.collectionViews.cells.containing(NSPredicate(format: "label BEGINSWITH 'Indoor' OR label CONTAINS 'Indoor'")).firstMatch
        row.tap()
        sleep(6)
        screenshot("50-indoor")
        app.swipeUp()
        sleep(1)
        screenshot("51-indoor-2")
        app.swipeUp()
        if app.buttons["All numbers"].exists { app.buttons["All numbers"].tap(); sleep(1); screenshot("52-indoor-numbers") }
    }
}
