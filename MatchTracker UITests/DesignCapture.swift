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
}
