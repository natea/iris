import XCTest

/// Opens Runs with the DEBUG progress fixtures, taps a run, and checks that
/// the detail screen really shows that run's steps. The screen is only worth
/// anything if the tap gets there, which a preview cannot prove.
final class RunProgressUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiPreviewState", "progress", "-uiPreviewScreen", "runs"] + extra
        app.launch()
        return app
    }

    func testTappingARunOpensItsProgress() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Runs"].waitForExistence(timeout: 15))

        let row = app.cells.containing(
            NSPredicate(format: "label CONTAINS[c] 'Audit the workspace dependencies'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the active run's row should be listed")
        row.tap()

        // Pushed inside the Runs sheet's own stack. The title is a readable
        // summary of the task; the run id is small print at the bottom.
        let title = app.navigationBars.containing(
            NSPredicate(format: "identifier CONTAINS[c] 'Audit the workspace dependencies'")
        ).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the title should summarise the task")
        XCTAssertFalse(app.navigationBars["run-8f21a0c4d9"].exists, "the run id is not the title")
        XCTAssertTrue(app.staticTexts["Running code"].waitForExistence(timeout: 5),
                      "the live headline should be on screen")
        XCTAssertTrue(app.buttons["5 steps, expanded"].waitForExistence(timeout: 5),
                      "the collapsible step count should be on screen")

        let step = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'web search,'")).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 5),
                      "a step should read as its tool, preview and state")
    }

    /// The list rows themselves carry §12.1's two fields for an active run.
    func testActiveRowsShowTheLiveHeadlineAndStepCount() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Runs"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Running code · 5 steps"].waitForExistence(timeout: 10))
    }

    /// §12.4: a run with no recorded steps must say so rather than look idle.
    func testARunWithNoStepHistorySaysSo() {
        let app = launch(extra: ["-uiPreviewRun", "run-55aa10d2ef"])
        let notice = app.staticTexts["Iris doesn't have the step history for this run — it's still working."]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
    }
}
