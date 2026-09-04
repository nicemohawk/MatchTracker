// UITestHelpers.swift
// MatchTracker UITests
//
// Shared helpers for the iOS UI-test bundle. These deliberately locate elements by visible
// label text and system queries only — no app-side accessibilityIdentifiers — so the tests stay
// decoupled from in-flight UI work in the app target.

import XCTest

// MARK: - HealthKit permission sheet

extension XCTestCase {

    /// Drives the HealthKit "Health Access" authorization sheet after something in the app triggers
    /// `HKHealthStore.requestAuthorization`.
    ///
    /// What actually works — validated live on iOS 26.0 simulator (iPhone 17):
    /// * The sheet is a remote view **bridged into the app-under-test's own element tree** — it is
    ///   NOT in Springboard, NOT in the (not-running) `com.apple.Health` app, and is NOT caught by
    ///   `addUIInterruptionMonitor`. All three of those approaches were tried and failed.
    /// * Its controls only surface through `descendants(matching: .any)` combined with an
    ///   `elementType` predicate. The typed `.buttons` / `.switches` queries return only the app's
    ///   own chrome (the tab bar), never the sheet's controls.
    /// * Observed element types: the "Health Access" title and each scope row label are staticText
    ///   (48); each scope toggle is a switch (40) with value "0"/"1"; "Allow" and "Don't Allow" are
    ///   buttons (9). "Allow" opens **disabled** and there is no accessible "Turn On All" element.
    ///
    /// Granting correctly on the first prompt is essential: the sheet opens with every toggle OFF
    /// and "Allow" disabled; tapping "Allow" in that state permanently denies access and iOS never
    /// re-prompts, later surfacing as "Not authorized" when the app saves/reads workouts (and, since
    /// the app under test is uninstalled/reinstalled per run, that denial persists across runs until
    /// the next fresh install). So we grant everything before confirming:
    ///  1. Tap a real "Turn On All" control if one is exposed (turns every scope on at once, avoiding
    ///     the per-switch coupled-scope dialogs). Matched by label — best-effort, often absent.
    ///  2. Toggle every scope switch still off directly. This is position-independent (works on
    ///     iPhone AND iPad, where the sheet is a centered form sheet so a hardcoded normalized
    ///     coordinate misses), accepting the coupled confirmation dialog ("… will also allow …
    ///     workouts" → "Enable workouts") each raises.
    ///  3. Wait for "Allow" to enable, then tap it.
    /// Granting read as well as write matters: the demo workouts are written and then read back to
    /// populate the Matches list, so read authorization must be on too.
    ///
    /// Best-effort: if no sheet appears (already authorized), returns quietly.
    ///
    /// - Parameters:
    ///   - app: the application under test — the sheet lives in its element tree.
    ///   - timeout: how long to wait for the sheet to appear (default 12s).
    func handleHealthKitPrompt(app: XCUIApplication, timeout: TimeInterval = 12) {
        // elementType raw values observed on the live sheet: button = 9, switch = 40, staticText = 48.
        let anyDescendant = app.descendants(matching: .any)
        let title = anyDescendant.matching(
            NSPredicate(format: "elementType == 48 AND label == 'Health Access'")).firstMatch
        let allow = anyDescendant.matching(
            NSPredicate(format: "elementType == 9 AND label == 'Allow'")).firstMatch

        guard title.waitForExistence(timeout: timeout) || allow.exists else {
            return // No sheet — already authorized on this install.
        }

        // Primary (best-effort): a real "Turn On All" control if the system exposes one — turns
        // every scope on atomically, avoiding the per-switch coupled-scope dialogs. Often there is
        // no such element in the tree, in which case the switch loop below does the work. This is
        // matched by label (never by a hardcoded coordinate, which misses on the iPad form sheet).
        let turnOnAll = anyDescendant.matching(
            NSPredicate(format: "(elementType == 9 OR elementType == 48) AND label CONTAINS[c] 'Turn On All'")).firstMatch
        if turnOnAll.waitForExistence(timeout: 1) && turnOnAll.isHittable {
            turnOnAll.tap()
            usleep(400_000)
        }

        // Reliable path on every device: turn on any scope switch still off. Position-independent,
        // so it works on the iPad centered form sheet too. Toggling a write scope can raise a coupled
        // confirmation ("… will also allow … workouts" → "Enable workouts"), which we accept.
        let switches = anyDescendant.matching(NSPredicate(format: "elementType == 40"))
        let switchCount = switches.count
        for index in 0..<switchCount {
            let toggle = switches.element(boundBy: index)
            guard toggle.exists, toggle.isHittable, (toggle.value as? String) == "0" else { continue }
            toggle.tap()
            acceptCoupledScopeDialog(in: app)
        }

        // "Allow" enables once the scopes are on; wait for it, then confirm. On the iPad form sheet
        // the bridged "Allow" button is visible + enabled but often reports `isHittable == false`, so
        // a plain `.tap()` is skipped and the sheet lingers — blocking every downstream step. Retry
        // until the sheet is gone, falling back to tapping the element's own frame by coordinate
        // (which lands regardless of the hittability flag).
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if title.exists == false && allow.exists == false { break } // sheet dismissed
            if allow.exists && allow.isEnabled {
                if allow.isHittable {
                    allow.tap()
                } else {
                    allow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }
                if title.waitForNonExistence(timeout: 2) { break }
            }
            usleep(250_000)
        }
        _ = title.waitForNonExistence(timeout: 5)
    }

    /// Accepts the coupled-scope confirmation dialog HealthKit shows when enabling a write scope that
    /// implies another (its confirm button is "Enable …"). Best-effort; returns if none appears.
    private func acceptCoupledScopeDialog(in app: XCUIApplication) {
        let enable = app.descendants(matching: .any)
            .matching(NSPredicate(format: "elementType == 9 AND label BEGINSWITH 'Enable'")).firstMatch
        if enable.waitForExistence(timeout: 1) && enable.isHittable {
            enable.tap()
        }
    }
}

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

// MARK: - Navigation helpers

extension XCTestCase {

    /// Opens the global Settings sheet. The settings affordance has moved around (currently a
    /// floating glass gearshape button pinned bottom-trailing), so we try several defensive queries
    /// in priority order rather than pinning to one layout.
    /// - Returns: true if a Settings surface was reached (the "Settings" nav title appears).
    @discardableResult
    func openSettings(app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        // Candidate ways to reach settings, most-specific first.
        let candidates: [() -> XCUIElement] = [
            { app.buttons["Settings"] },                 // accessibilityLabel("Settings")
            { app.buttons["gearshape"] },                // SF Symbol name, if surfaced
            { app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'settings'")).firstMatch },
            { app.images["gearshape"] },
            { app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'settings'")).firstMatch }
        ]

        for candidate in candidates {
            let element = candidate()
            if element.waitForExistence(timeout: 2) && element.isHittable {
                element.tap()
                if app.navigationBars["Settings"].waitForExistence(timeout: timeout)
                    || app.staticTexts["Settings"].waitForExistence(timeout: 2) {
                    return true
                }
            }
        }
        return false
    }

    /// Dismisses the Settings sheet and confirms it's gone. The confirm button lives in the nav bar
    /// and its title has varied ("Done"/"Save"/"Close"), so we try those via both the navigation-bar
    /// and top-level button queries, verify the "Settings" title disappears, and fall back to
    /// dragging the sheet down from its top grabber if a tap didn't take.
    func closeSettings(app: XCUIApplication) {
        let settingsTitle = app.staticTexts["Settings"]
        for _ in 0..<3 {
            let candidates = [
                app.navigationBars.buttons["Done"], app.navigationBars.buttons["Save"],
                app.navigationBars.buttons["Close"], app.buttons["Done"],
                app.buttons["Save"], app.buttons["Close"]
            ]
            if let button = candidates.first(where: { $0.exists && $0.isHittable }) {
                button.tap()
            }
            if !settingsTitle.waitForExistence(timeout: 2) { return } // title gone → dismissed
            // Tap didn't dismiss — drag the sheet down from the top grabber.
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
            let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            top.press(forDuration: 0.1, thenDragTo: bottom)
        }
    }

    /// Scrolls the app's main scroll view until `element` exists and is hittable, or `maxSwipes`
    /// is exhausted. Needed for SwiftUI `Form`/`List`, which lazily materializes off-screen rows so
    /// they aren't in the accessibility tree until scrolled into view.
    @discardableResult
    func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) -> Bool {
        var swipes = 0
        while swipes < maxSwipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp(velocity: .fast)
            swipes += 1
        }
        return element.exists && element.isHittable
    }

    /// Switches to a tab and waits for its screen. Two layouts to satisfy:
    /// * iPhone (iOS 26): a bottom `tabBar` that minimizes on scroll — a plain `.tap()` sometimes
    ///   doesn't land, so we re-expand a minimized bar by tapping it before re-tapping the target.
    /// * iPad (iOS 26): the tabs render as a top-center pill whose buttons are NOT inside a
    ///   `tabBars` element — so we also query the label app-wide (`app.buttons[name]`).
    /// - Returns: true once `navBarTitle` appears.
    @discardableResult
    /// Variant for chrome-less tabs (Fields hides its nav bar): waits for a marker element
    /// matching `labelContains` instead of a navigation bar title.
    func selectTab(_ name: String, expectingLabelContains marker: String, in app: XCUIApplication) -> Bool {
        let tabBarButton = app.tabBars.buttons[name]
        let anyButton = app.buttons[name]
        let markerElement = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", marker)).firstMatch
        for _ in 0..<5 {
            if markerElement.exists { return true }
            if tabBarButton.exists && tabBarButton.isHittable {
                tabBarButton.tap()
            } else if anyButton.exists && anyButton.isHittable {
                anyButton.tap()
            } else if app.tabBars.firstMatch.exists {
                app.tabBars.firstMatch.tap()
            }
            if markerElement.waitForExistence(timeout: 4) { return true }
        }
        return markerElement.exists
    }

    func selectTab(_ name: String, expectingNavBar navBarTitle: String, in app: XCUIApplication) -> Bool {
        let tabBarButton = app.tabBars.buttons[name]
        let anyButton = app.buttons[name]
        for _ in 0..<5 {
            if app.navigationBars[navBarTitle].exists { return true }
            if tabBarButton.exists && tabBarButton.isHittable {
                tabBarButton.tap()
            } else if anyButton.exists && anyButton.isHittable {
                // iPad top pill (or any labeled tab control outside a tabBars container).
                anyButton.tap()
            } else if app.tabBars.firstMatch.exists {
                // Minimized tab bar — tapping the bar re-expands it so the button becomes hittable.
                app.tabBars.firstMatch.tap()
            }
            if app.navigationBars[navBarTitle].waitForExistence(timeout: 4) { return true }
        }
        return app.navigationBars[navBarTitle].exists
    }

    /// Clears any text already in `field` before typing `text`. A field's `value` falls back to its
    /// placeholder when empty, so a value equal to `placeholder` is treated as empty. Fixes fields
    /// that accumulate across the reinstall-per-run tests (notably the team code, which appended).
    func clearAndType(_ field: XCUIElement, text: String, placeholder: String? = nil) {
        guard field.exists else { return }
        field.tap()
        let current = (field.value as? String) ?? ""
        if !current.isEmpty, current != placeholder {
            // Move the caret to the end before backspacing: center-tapping a right-aligned field
            // (these use `.multilineTextAlignment(.trailing)`) lands the caret BEFORE the text, so
            // plain backspaces would no-op and the new text would just prepend (e.g. "BenBen").
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        field.typeText(text)
    }

    /// Dismisses a system location-authorization alert if one appears. It's a Springboard alert with
    /// "Allow Once" / "Allow While Using App" / "Don't Allow" — we grant "Allow While Using App"
    /// (falling back to "Allow Once"). Best-effort: returns quietly if no alert shows.
    func dismissLocationPromptIfPresent(timeout: TimeInterval = 8) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        let titles = ["Allow While Using App", "Allow Once", "Allow"]
        while Date() < deadline {
            for title in titles {
                let button = springboard.buttons[title]
                if button.exists && button.isHittable {
                    button.tap()
                    return
                }
            }
            usleep(300_000)
        }
    }
}
