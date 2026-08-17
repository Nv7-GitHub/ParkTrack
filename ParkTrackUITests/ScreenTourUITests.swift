import XCTest

/// Walks every tab and captures a screenshot of each, so the UI can be reviewed without
/// a human driving the simulator. Failures here mean a screen didn't render at all.
///
/// Skipped by the scheme, because these launch the app five times and let a real map sweep
/// run — minutes, against seconds for the whole unit suite. The everyday check is the unit
/// tests; this is for when the change is one only a screenshot can confirm:
///
///     xcodebuild ... -only-testing:ParkTrackUITests test
///
/// The gate is in `project.yml` rather than an environment variable because xcodebuild does
/// not forward the shell's variables to a UI test's runner process, so a variable read here
/// would be absent however the command was written — and the tour would skip even when it
/// had been asked for.
final class ScreenTourUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Dismiss the location prompt automatically so the tour isn't blocked by it.
        addUIInterruptionMonitor(withDescription: "Location permission") { alert in
            for label in ["Allow While Using App", "Allow Once", "OK", "Allow"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
        app.launch()
        dismissLocationPromptIfPresent()
    }

    /// The interruption monitor only fires on the next interaction, which is too late when the
    /// very first thing we want is a clean screenshot. Tap the system alert directly instead.
    ///
    /// One wait across all three labels rather than one wait each: the permission is usually
    /// already granted, and three sequential eight-second timeouts spent finding nothing was
    /// costing most of a minute across the suite.
    private func dismissLocationPromptIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(
            NSPredicate(format: "label IN %@", ["Allow While Using App", "Allow Once", "Allow"])
        ).firstMatch
        if allow.waitForExistence(timeout: 4) { allow.tap() }
    }

    // MARK: - Waiting

    /// Blocks until `condition` holds, checking often, instead of guessing at a duration.
    ///
    /// Every wait in this file used to be a fixed sleep sized for the slowest imaginable
    /// case, so the suite paid the worst case every single time even when the screen was
    /// ready immediately.
    @discardableResult
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 30,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    /// Waits for the launch sweep to put something on screen.
    ///
    /// Home shows the first-run card while it has no parks and swaps it for the rings once
    /// it does, so the card's absence is the signal — and on a device that already has parks
    /// cached it is true immediately.
    private func waitForParks(timeout: TimeInterval = 60) {
        waitUntil("parks discovered", timeout: timeout) {
            !app.staticTexts["Looking around you…"].exists
                && !app.staticTexts["No parks found yet"].exists
        }
    }

    /// A short pause for animation and layout to finish, once the thing being waited for
    /// already exists. Screenshots mid-transition are the one thing worth sleeping for.
    private func settle(_ seconds: TimeInterval = 0.6) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func openTab(_ name: String) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Missing \(name) tab")
        button.tap()
        settle()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTourEveryTab() throws {
        waitForParks()
        capture("01-home")

        for (index, tab) in ["Map", "Parks", "Stats", "Friends"].enumerated() {
            openTab(tab)
            // The map needs its tiles before a screenshot means anything; the rest are
            // ready as soon as their content exists.
            if tab == "Map" {
                waitUntil("map rendered", timeout: 20) { app.descendants(matching: .map).firstMatch.exists }
                settle(1.5)
            }
            capture(String(format: "%02d-%@", index + 2, tab.lowercased()))
        }

        openTab("Home")
        let gear = app.buttons["Settings"]
        if gear.waitForExistence(timeout: 5) {
            gear.tap()
            waitUntil("settings open", timeout: 10) { app.staticTexts["Data"].exists }
            settle()
            capture("06-settings")
        }
    }

    /// Captures every tab scrolled to its end.
    ///
    /// The floating tab bar sits over the content rather than shortening it, so a screen that
    /// forgot to reserve room for it looks fine until you reach the bottom — which is the one
    /// place the plain tour never visits.
    func testTourEveryTabAtTheEndOfItsScroll() throws {
        waitForParks()
        scrollToBottom()
        capture("11-home-bottom")

        for (index, tab) in ["Parks", "Stats", "Friends"].enumerated() {
            openTab(tab)
            // Parks opens on "Visited", which is empty on a fresh install and so scrolls
            // nowhere. The discovered list is the one that can run under the tab bar.
            if tab == "Parks" {
                let toGo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'To go'")).firstMatch
                if toGo.waitForExistence(timeout: 5) {
                    toGo.tap()
                    settle()
                }
            }
            scrollToBottom()
            capture(String(format: "%02d-%@-bottom", index + 12, tab.lowercased()))
        }
    }

    private func scrollToBottom() {
        for _ in 0..<20 { app.swipeUp(velocity: .fast) }
        settle()
    }

    /// Waits for the initial sweep to populate the store, then scrolls Stats to the region
    /// section — the completion-by-area block only exists once parks have been placed.
    func testRegionCompletionSection() throws {
        waitForParks()
        openTab("Stats")
        // The section appears only once the geocoder has named somewhere, which is the
        // slowest thing the app does on a fresh install.
        waitUntil("region section", timeout: 60) { app.staticTexts["Completion by area"].exists }
        app.swipeUp()
        settle()
        capture("30-stats-regions")
        app.swipeUp()
        settle()
        capture("31-stats-regions-lower")
    }

    /// Zooms the map in far enough that park name labels should appear, and confirms the
    /// footprint bubbles are gone.
    func testMapZoomedInShowsParkNames() throws {
        waitForParks()
        openTab("Map")

        let map = app.descendants(matching: .map).firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 20), "The map never rendered")
        settle(1.5)
        capture("20-map-default")

        for _ in 0..<3 {
            map.pinch(withScale: 3.0, velocity: 3.0)
            settle(0.8)
        }
        // The camera has to settle before the annotation set is rebuilt for the new zoom.
        settle(2)
        capture("21-map-zoomed")
    }

    /// Scrolls the stats screen so the charts further down are captured too.
    func testStatsScrolled() throws {
        waitForParks()
        openTab("Stats")
        waitUntil("stats content", timeout: 20) { app.staticTexts["Your collection"].exists }
        app.swipeUp()
        app.swipeUp()
        settle()
        capture("07-stats-scrolled")
        app.swipeUp()
        app.swipeUp()
        settle()
        capture("08-stats-lower")
    }
}
