import XCTest

/// The Settings section for LINK_API.md §14. It exists so a person can answer
/// "is this on, is it running, and does my Mac know how to update it" without
/// guessing — so a UI test opens Settings and looks for it the way a person
/// would, by scrolling.
final class LiveActivitySettingsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testSettingsShowsTheLiveActivityAndWidgetSection() {
        let app = XCUIApplication()
        app.launch()

        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        let header = app.staticTexts["Live Activity & widget"]
        let toggle = app.switches["live-activity-toggle"]
        for _ in 0..<8 {
            if header.exists && toggle.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(header.exists, "the Live Activity & widget section must be reachable in Settings")
        XCTAssertTrue(toggle.exists, "the section must carry the enable/disable switch")
        XCTAssertTrue(app.staticTexts["Allowed by iOS"].exists,
                      "whether iOS permits Live Activities is stated, never assumed")
    }
}
