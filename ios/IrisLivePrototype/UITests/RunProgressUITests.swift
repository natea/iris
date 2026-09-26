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

/// LINK_API.md §15 on screen: a failed run says WHY, in the Mac's own words,
/// and offers the one-tap recovery behind a single confirmation.
///
/// These fixtures have no Link service behind them, so a tap here can never
/// start a real chat or dispatch anything.
final class RunFailureUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(run: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiPreviewState", "progress", "-uiPreviewScreen", "runs", "-uiPreviewRun", run,
        ]
        app.launch()
        return app
    }

    private static let lockedSentence =
        "That chat is open in Hermes Desktop. Close it there, or I can start a new chat."

    /// SwiftUI decides for itself whether a control surfaces as a button, a
    /// cell or a plain element; the identifier is the stable part, so query on
    /// that rather than on the element type.
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testTheFailureCardLeadsWithTheRealReason() {
        let app = launch(run: "run-4e19bb70c3")
        let message = element("failure-message", in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 15), "the failure card should be on screen")
        XCTAssertEqual(message.label, Self.lockedSentence)

        // The sentence that used to be shown for this, and must not be now.
        XCTAssertFalse(
            app.staticTexts["Hermes is not reachable from your Mac. Nothing was sent."].exists,
            "the generic sentence must be gone"
        )
        // No result section for a run that produced nothing.
        XCTAssertFalse(app.staticTexts["Result"].exists)
    }

    func testHermesOwnTextStaysAvailableBehindADisclosure() {
        let app = launch(run: "run-4e19bb70c3")
        let disclosure = element("failure-detail-disclosure", in: app)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 15))
        // Collapsed by default: the raw text is for debugging, not the headline.
        XCTAssertFalse(element("failure-detail", in: app).exists)
        disclosure.tap()
        // Expanded, Hermes' own words are on screen verbatim. Matched on the
        // text rather than on an identifier: what matters is that the raw
        // sentence is readable, not which element ended up carrying it.
        let raw = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'another Hermes window/terminal'")
        ).firstMatch
        XCTAssertTrue(raw.waitForExistence(timeout: 10),
                      "Hermes' own text should be available behind the disclosure")
    }

    func testTheRecoveryButtonConfirmsBeforeItDoesAnything() {
        let app = launch(run: "run-4e19bb70c3")
        let button = element("recovery-start-new-chat", in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 15), "the recovery button should be offered")
        XCTAssertTrue(button.isHittable)
        XCTAssertGreaterThanOrEqual(button.frame.height, 44, "too small to hit: \(button.frame)")

        button.tap()
        // One confirmation, and it names the consequence the user cannot see
        // from the phone: the Mac's pinned chat changes too.
        let dialog = app.sheets["Start a new Hermes chat?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 10), "the tap must confirm before it acts")
        let consequence = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'on your Mac too'")
        ).firstMatch
        XCTAssertTrue(consequence.waitForExistence(timeout: 10),
                      "the confirmation must say what changes")

        // Refusable, and refusing changes nothing. (iOS 26 presents this as a
        // popover anchored to the button, with no separate Cancel element —
        // a tap outside is the way out, so that is what is exercised.)
        app.tap()
        XCTAssertTrue(element("recovery-start-new-chat", in: app).waitForExistence(timeout: 10),
                      "after refusing, the card is unchanged and nothing was started")
        XCTAssertFalse(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'Started a new Hermes chat'")
        ).firstMatch.exists, "nothing may claim a chat was started")
    }

    /// A failure nobody can fix from the phone offers advice, not a button.
    func testABackendFailureOffersNoButtonAndNamesTheCause() {
        let app = launch(run: "run-91f0ac4d22")
        let message = element("failure-message", in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 15))
        XCTAssertEqual(
            message.label,
            "Hermes' backend would not start (MCP server 'strava' failed to authenticate)."
        )
        XCTAssertTrue(element("recovery-check-mac", in: app).exists)
        XCTAssertFalse(element("recovery-start-new-chat", in: app).exists,
                       "nothing a tap can fix here, so no button")
    }

    /// §16.3 — a run rebuilt from the transcript is read-only.
    func testARestoredRunHasNoStopAndNoRecovery() {
        let app = launch(run: "history:20260916_174926_797a3b:msg_412")
        XCTAssertTrue(app.navigationBars.element.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Stop this run"].exists, "history cannot be stopped")
        XCTAssertFalse(element("recovery-start-new-chat", in: app).exists)
    }

    /// The list row itself says why, so a reason is not something only the
    /// detail screen could tell you.
    func testTheRunsListRowCarriesTheReason() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiPreviewState", "progress", "-uiPreviewScreen", "runs"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Runs"].waitForExistence(timeout: 15))
        let row = app.cells.containing(
            NSPredicate(format: "label CONTAINS[c] 'open in Hermes Desktop'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the failed row should say why in the list")
    }
}
