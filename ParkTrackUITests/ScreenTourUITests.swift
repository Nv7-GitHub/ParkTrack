import XCTest

/// Walks every tab and captures a screenshot of each, so the UI can be reviewed without
/// a human driving the simulator. Failures here mean a screen didn't render at all.
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
    private func dismissLocationPromptIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow While Using App", "Allow Once", "Allow"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 8) {
                button.tap()
                return
            }
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTourEveryTab() throws {
        // Give discovery a moment to populate the first screen.
        Thread.sleep(forTimeInterval: 12)
        capture("01-home")

        let tabs = ["Map", "Parks", "Stats", "Friends"]
        for (index, tab) in tabs.enumerated() {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "Missing \(tab) tab")
            button.tap()
            Thread.sleep(forTimeInterval: tab == "Map" ? 10 : 5)
            capture(String(format: "%02d-%@", index + 2, tab.lowercased()))
        }

        // Back to Home, then open Settings via the gear overlay.
        app.tabBars.buttons["Home"].tap()
        Thread.sleep(forTimeInterval: 2)
        let gear = app.buttons["Settings"]
        if gear.waitForExistence(timeout: 5) {
            gear.tap()
            Thread.sleep(forTimeInterval: 3)
            capture("06-settings")
        }
    }

    /// Scrolls the stats screen so the charts further down are captured too.
    func testStatsScrolled() throws {
        Thread.sleep(forTimeInterval: 8)
        app.tabBars.buttons["Stats"].tap()
        Thread.sleep(forTimeInterval: 4)
        app.swipeUp()
        app.swipeUp()
        Thread.sleep(forTimeInterval: 2)
        capture("07-stats-scrolled")
        app.swipeUp()
        app.swipeUp()
        Thread.sleep(forTimeInterval: 2)
        capture("08-stats-lower")
    }
}
