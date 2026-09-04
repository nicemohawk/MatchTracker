// WatchUITestHelpers.swift
// MatchTracker Watch UITests
//
// Shared helpers for the watchOS UI-test bundle. Like the iOS bundle, these locate elements by
// visible label text and system queries only — no app-side accessibilityIdentifiers — so the tests
// stay decoupled from in-flight UI work in the watch app target.

import XCTest

// MARK: - Screenshots

extension XCTestCase {

    /// Captures the current screen (or a specific app's) as a permanently-kept attachment.
    @discardableResult
    func screenshot(_ name: String, app: XCUIApplication? = nil) -> XCTAttachment {
        let image = (app ?? XCUIApplication()).screenshot().image
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return attachment
    }
}

// MARK: - watchOS HealthKit permission sheet

extension XCTestCase {

    /// The watchOS system process that hosts the HealthKit authorization sheet.
    var watchCarousel: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.Carousel") }

    /// Drives the watchOS HealthKit authorization sheet that appears when the watch app calls
    /// `HKHealthStore.requestAuthorization` on launch (see `MatchTrackerWatchApp` → `.task`).
    ///
    /// RECIPE — validated live on the watchOS 26.5 simulator (Apple Watch Series 11):
    /// * The sheet is a **system remote view hosted in `com.apple.Carousel`** (the watch home
    ///   screen process), NOT in the app-under-test's element tree. Querying `XCUIApplication()`
    ///   (the app) finds nothing; you must query `XCUIApplication(bundleIdentifier:
    ///   "com.apple.Carousel")`. The app's own Start button stays present in its tree *behind* the
    ///   sheet, so asserting on it alone is a false pass — the sheet has to be dismissed first, or
    ///   every screenshot just shows the sheet.
    /// * It's a multi-page flow, each page rendered as a scrolling `Alert`:
    ///   1. **Intro** — a button `UIA.Health.WatchAuthSheet.ReviewButton` (label "Review"). Tap it.
    ///   2. **"Write Access"** — a single master toggle `UIA.Health.WatchAuthSheet.SwitchOutlet`
    ///      (labelled "All Requested Data Below") that turns on every requested write scope at once.
    ///      It's at the top of the page (hittable only while scrolled to top). Below the fold sits
    ///      the advance control **"Next"**, which surfaces as a *staticText*, not a button.
    ///   3. **"Read Access"** — same shape; advance is "Next" then the final confirm.
    ///   4. **Final** — confirmed with "Done" / "Allow" / "Turn On".
    /// * The confirm/advance controls ("Next"/"Done"/"Allow") are NOT in `carousel.buttons`; they
    ///   only appear via `carousel.staticTexts`, and need scrolling into view. So we search both the
    ///   button and staticText collections, and swipe up to reveal them.
    /// * Granting matters: the master toggle grants both read and write scopes across pages — the
    ///   app writes workouts and reads them back, so both must be on.
    ///
    /// Strategy: query Carousel; wait for the sheet; then per page — turn on the master `SwitchOutlet`
    /// (and any other switch still off), swipe up to reveal the footer, tap whichever advance/confirm
    /// control is reachable ("Review"/"Next"/"Allow"/"Turn On"/"Done"/"Continue") — looping until no
    /// sheet page remains. Best-effort: if no sheet ever appears (already authorized), returns quietly.
    ///
    /// - Parameters:
    ///   - timeout: overall budget for driving the sheet to completion (default 60s; the watch sim
    ///     is slow and the sheet is several pages).
    /// - Returns: true if the sheet appeared and was driven, false if none appeared.
    @discardableResult
    func handleWatchHealthKitPrompt(timeout: TimeInterval = 60) -> Bool {
        let carousel = watchCarousel

        // Advance/confirm control labels, highest priority first. These may be a button OR a
        // staticText, so we look in both collections. "Review" advances the intro page.
        let advanceLabels = ["Review", "Turn On All", "Allow All", "Turn On",
                            "Allow", "Next", "Continue", "Done", "Save", "OK"]

        /// A reachable advance/confirm control (button or staticText) for `label`, if any.
        func advanceControl() -> XCUIElement? {
            for label in advanceLabels {
                let predicate = NSPredicate(format: "label ==[c] %@", label)
                let button = carousel.buttons.matching(predicate).firstMatch
                if button.exists && button.isHittable { return button }
                let text = carousel.staticTexts.matching(predicate).firstMatch
                if text.exists && text.isHittable { return text }
            }
            return nil
        }

        /// True while any HealthKit-sheet page is on screen (by title text or the scope toggle).
        func sheetIsPresent() -> Bool {
            for title in ["Health Access", "Write Access", "Read Access"]
            where carousel.staticTexts[title].exists { return true }
            if carousel.switches["UIA.Health.WatchAuthSheet.SwitchOutlet"].exists { return true }
            if carousel.buttons["UIA.Health.WatchAuthSheet.ReviewButton"].exists { return true }
            return false
        }

        // Wait for the sheet to first appear. If it never does, the app was already authorized.
        let appearDeadline = Date().addingTimeInterval(min(timeout, 25))
        while Date() < appearDeadline && !sheetIsPresent() {
            usleep(300_000)
        }
        guard sheetIsPresent() else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        var idlePasses = 0

        while Date() < deadline {
            var didSomething = false

            // 1. Turn on every scope switch still off (the master toggle grants everything at once).
            let switches = carousel.switches
            for index in 0..<switches.count {
                let toggle = switches.element(boundBy: index)
                guard toggle.exists, toggle.isHittable, (toggle.value as? String) == "0" else { continue }
                toggle.tap()
                didSomething = true
                usleep(300_000)
            }

            // 2. Tap the highest-priority advance/confirm control that's currently reachable.
            if let control = advanceControl() {
                control.tap()
                didSomething = true
                usleep(700_000)
            } else if sheetIsPresent() {
                // Advance control is below the fold — scroll the page footer into view and retry.
                carousel.swipeUp()
                didSomething = true
                usleep(400_000)
            }

            // 3. Stop once no sheet page remains, or after a few idle passes with nothing to do.
            if !sheetIsPresent() { break }
            if !didSomething {
                idlePasses += 1
                if idlePasses >= 4 { break }
                usleep(400_000)
            } else {
                idlePasses = 0
            }
        }

        return true
    }

    /// Grants a watchOS location-authorization alert if one appears. `StartFieldDetector` on the
    /// start screen calls `requestWhenInUseAuthorization`, raising an alert (hosted in Carousel) with
    /// "Allow While Using App" / "Allow Once" / "Don't Allow". Grants "Allow While Using App"
    /// (falling back to "Allow Once").
    ///
    /// NOTE — validated on the watchOS 26.5 simulator: the alert is a *scrolling* sheet. Its title
    /// and a map preview fill the viewport, and the action buttons sit BELOW the fold (measured
    /// around y≈471 on a ~248pt-tall screen), so they `exist` but are not `isHittable` until the
    /// alert is scrolled down. We swipe up to bring them into view before tapping. Best-effort;
    /// returns quietly if no alert shows.
    @discardableResult
    func handleWatchLocationPrompt(timeout: TimeInterval = 10) -> Bool {
        let carousel = watchCarousel
        let deadline = Date().addingTimeInterval(timeout)
        let labels = ["Allow While Using App", "Allow Once", "Allow"]

        func allowButton() -> XCUIElement? {
            for label in labels {
                let button = carousel.buttons.matching(
                    NSPredicate(format: "label ==[c] %@", label)).firstMatch
                if button.exists { return button }
            }
            return nil
        }

        // Wait for the alert to appear.
        while Date() < deadline {
            if carousel.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] 'use your location'")).firstMatch.exists
                || allowButton() != nil { break }
            usleep(300_000)
        }

        // Scroll the Allow button into view, then tap it.
        while Date() < deadline {
            if let button = allowButton() {
                if button.isHittable {
                    button.tap()
                    return true
                }
                carousel.swipeUp() // buttons are below the fold — scroll them up
                usleep(400_000)
            } else {
                usleep(300_000)
            }
        }
        return false
    }

    /// Best-effort dismissal of the HealthKit sheet without granting — a fallback for when the flow
    /// can't be driven to completion. Taps a cancel/close affordance, then the "Back" button, then a
    /// top-left corner tap. Returns true if a dismissal control was found and tapped.
    @discardableResult
    func dismissWatchHealthKitSheet() -> Bool {
        let carousel = watchCarousel
        for label in ["Cancel", "Close", "Dismiss", "Not Now", "Don't Allow", "Back"] {
            let button = carousel.buttons.matching(
                NSPredicate(format: "label ==[c] %@", label)).firstMatch
            if button.exists && button.isHittable {
                button.tap()
                return true
            }
        }
        if carousel.staticTexts["Health Access"].exists {
            carousel.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.15)).tap()
            return true
        }
        return false
    }
}

// MARK: - Watch Settings toggles

extension XCTestCase {

    /// Drives the "Referee mode" toggle in watch Settings to `on` and VERIFIES it engaged.
    ///
    /// Verification is end-to-end, keyed on visible UI rather than switch-value plumbing: the start
    /// screen renders a "Referee mode" banner label if — and only if — `WatchSettings.refereeMode`
    /// is true. So the recipe is: read the banner to learn the current state; if it already matches,
    /// done. Otherwise open Settings (scrolling to the link), tap the Referee-mode toggle (its
    /// `switch` element when queryable, else the labelled row), then RELAUNCH the app — the setting
    /// persists in app-group defaults, and relaunching both lands us on a deterministic start screen
    /// and re-reads the setting — and confirm the banner now matches the target.
    ///
    /// Assumes the start screen is on top when called. On success the app is freshly launched and
    /// parked on the start screen. Returns false if the toggle could not be verified in the target
    /// state — callers should fail loudly rather than proceed and capture the wrong mode.
    @discardableResult
    func setRefereeMode(_ on: Bool, app: XCUIApplication) -> Bool {
        let startButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Start Match'")).firstMatch

        // The banner exists in the element tree even when scrolled below the fold, so `exists`
        // (not `isHittable`) is the right read.
        func bannerVisible() -> Bool {
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] 'Referee mode'")).firstMatch.exists
        }

        guard startButton.waitForExistence(timeout: 20) else { return false }
        if bannerVisible() == on { return true }

        // Open Settings — its NavigationLink sits below Start/format/field-status/Train-Field.
        let settingsLink = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Settings'")).firstMatch
        var reached = settingsLink.waitForExistence(timeout: 5) && settingsLink.isHittable
        var swipes = 0
        while !reached && swipes < 5 {
            app.swipeUp()
            swipes += 1
            reached = settingsLink.exists && settingsLink.isHittable
        }
        guard reached else { return false }
        settingsLink.tap()

        // Tap the Referee-mode toggle. Prefer the switch element; fall back to any labelled element
        // (the row), whose center tap also flips the toggle.
        let refereeSwitch = app.switches.matching(
            NSPredicate(format: "label CONTAINS[c] 'Referee'")).firstMatch
        let refereeRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'Referee mode'")).firstMatch
        let target: XCUIElement = refereeSwitch.waitForExistence(timeout: 12) ? refereeSwitch : refereeRow
        guard target.waitForExistence(timeout: 8) else { return false }
        var toggleSwipes = 0
        while !target.isHittable && toggleSwipes < 4 {
            app.swipeUp()
            toggleSwipes += 1
        }
        guard target.isHittable else { return false }

        // The switch's `value` is an NSNumber-ish 0/1 (occasionally a string); normalize both.
        func switchIsOn() -> Bool {
            if let text = target.value as? String { return text == "1" }
            if let number = target.value as? NSNumber { return number.boolValue }
            return false
        }

        // A plain element .tap() computes a hit point that can land on the row's LABEL region,
        // which on watchOS does not flip the toggle (observed live: value stays 0). Escalate
        // through hit strategies until the value actually flips: the switch glyph sits at the
        // row's right edge, so coordinate taps there are the reliable fallback.
        var attempts = 0
        while switchIsOn() != on && attempts < 4 {
            switch attempts {
            case 0:
                target.tap()
            case 1:
                target.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
            case 2:
                let nested = target.switches.firstMatch
                if nested.exists {
                    nested.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                } else {
                    target.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
                }
            default:
                target.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            }
            attempts += 1
            usleep(900_000)
        }

        // Relaunch onto a fresh start screen and confirm the banner reflects the target state.
        // HealthKit/location are already granted on this install, so the prompts no-op.
        app.terminate()
        app.launch()
        _ = handleWatchHealthKitPrompt(timeout: 10)
        handleWatchLocationPrompt(timeout: 8)
        guard startButton.waitForExistence(timeout: 30) else { return false }
        usleep(500_000)
        return bannerVisible() == on
    }
}
