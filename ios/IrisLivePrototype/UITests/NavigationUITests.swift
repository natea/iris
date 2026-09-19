import XCTest

/// Taps the real controls. The redesign was first checked only by launching
/// straight into each screen, which hid a control bar that ignored touches.
final class NavigationUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testSettingsOpensFromTheControlBar() {
        let app = XCUIApplication()
        app.launch()
        let button = app.buttons["open-settings"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    func testRunsOpenFromTheControlBar() {
        let app = XCUIApplication()
        app.launch()
        let button = app.buttons["open-runs"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.isHittable)
        button.tap()
        XCTAssertTrue(app.navigationBars["Runs"].waitForExistence(timeout: 5))
    }

    /// The paired main screen is laid out differently (transcript, runs strip,
    /// banner), so the control bar must be tappable there too.
    func testControlBarWorksInPairedStates() {
        for state in ["listening", "working", "error", "proposal"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiPreviewState", state]
            app.launch()
            let settings = app.buttons["open-settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10), state)
            XCTAssertTrue(settings.isHittable, "settings not hittable in \(state)")
            settings.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "settings did not open in \(state)")
            app.terminate()
        }
    }
}
