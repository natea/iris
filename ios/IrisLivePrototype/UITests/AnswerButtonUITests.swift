import XCTest

/// The big answer buttons, driven through real taps on the DEBUG fixtures.
///
/// A preview proves the layout exists; only a launched app proves the buttons
/// are hittable, carry their labels, sit on the side the setting says, and do
/// not cover the brief they are answering. No Mac, no token, no network and no
/// audio is involved: the fixtures have no Link service behind them, so a tap
/// here can never dispatch anything.
final class ProposalAnswerButtonUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ state: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiPreviewState", state] + extra
        app.launch()
        return app
    }

    private func setHandedness(_ title: String, in app: XCUIApplication) {
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let choice = app.buttons[title]
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "\(title) should be offered")
        choice.tap()
        app.buttons["Done"].tap()
    }

    func testTheThreeAnswerButtonsAreThereAndHittable() {
        let app = launch("proposal")
        for id in ["answer-yes", "answer-no", "answer-explain"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 15), "\(id) is missing")
            XCTAssertTrue(button.isHittable, "\(id) is not hittable")
            // Big enough to hit without aiming.
            XCTAssertGreaterThanOrEqual(button.frame.height, 60, "\(id) is too small: \(button.frame)")
        }
        // VoiceOver has to say what each one does, not just its colour.
        XCTAssertEqual(app.buttons["answer-yes"].label, "Yes, send this to Hermes")
        XCTAssertEqual(app.buttons["answer-no"].label, "No, don't send")
        XCTAssertEqual(app.buttons["answer-explain"].label, "Let me explain a change")
    }

    func testTheControlBarIsStillReachableWhileTheButtonsAreUp() {
        let app = launch("proposal")
        XCTAssertTrue(app.buttons["answer-yes"].waitForExistence(timeout: 15))
        // The route picker is how AirPods get chosen; answering a question
        // must not take it away.
        XCTAssertTrue(app.otherElements["Choose audio output"].exists
                      || app.buttons["Choose audio output"].exists)
        XCTAssertTrue(app.buttons["open-settings"].isHittable)
    }

    func testYesSitsOnTheRightByDefaultAndMirrorsForALeftHandedUser() {
        let app = launch("proposal")
        let yes = app.buttons["answer-yes"]
        let no = app.buttons["answer-no"]
        let explain = app.buttons["answer-explain"]
        XCTAssertTrue(yes.waitForExistence(timeout: 15))

        XCTAssertGreaterThan(yes.frame.midX, no.frame.midX,
                             "right-handed: Yes belongs on the right")
        XCTAssertTrue(explain.frame.midX > no.frame.midX && explain.frame.midX < yes.frame.midX,
                      "the quieter option belongs between them")
        // All three in the bottom third: that is the thumb zone.
        let screen = app.windows.firstMatch.frame
        XCTAssertGreaterThan(yes.frame.minY, screen.height * 0.6, "the buttons are not in the thumb zone")

        setHandedness("Left-handed", in: app)
        XCTAssertTrue(yes.waitForExistence(timeout: 10))
        XCTAssertLessThan(yes.frame.midX, no.frame.midX,
                          "left-handed: Yes must move to the left")

        // Leave the simulator as it was found.
        setHandedness("Right-handed", in: app)
        XCTAssertGreaterThan(app.buttons["answer-yes"].frame.midX, app.buttons["answer-no"].frame.midX)
    }

    /// The rule the buttons make load-bearing: what a tap would send has to be
    /// readable first.
    func testTheWholeBriefIsReadableWhileTheButtonsAreUp() {
        let app = launch("proposal-long")
        let brief = app.otherElements["proposal-brief"]
        XCTAssertTrue(brief.waitForExistence(timeout: 15))
        // The accessibility label carries the complete brief, ellipsis-free.
        let label = brief.label
        XCTAssertTrue(label.contains("Re-run the dependency audit"), label)
        XCTAssertTrue(label.contains("newest gaps first"),
                      "the END of the brief must be reachable too: \(label)")
        XCTAssertFalse(label.contains("…"), "nothing may be truncated: \(label)")

        // And the card does not sit under the buttons.
        XCTAssertTrue(app.buttons["answer-yes"].waitForExistence(timeout: 5))
        XCTAssertLessThan(brief.frame.minY, app.buttons["answer-yes"].frame.minY)
    }
}

final class ApprovalAnswerButtonUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launchRun(_ runId: String, state: String = "approval") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiPreviewState", state,
            "-uiPreviewScreen", "runs",
            "-uiPreviewRun", runId,
        ]
        app.launch()
        return app
    }

    func testTheRunScreenOffersTwoBigButtonsAndTheFullCommand() {
        let app = launchRun("run-6d04bb92c1")
        // Distinct ids from the main screen's card: the main screen is still
        // in the hierarchy behind the sheet, and a test that cannot tell the
        // two apart proves nothing about either.
        let approve = app.buttons["run-approve"]
        let deny = app.buttons["run-deny"]
        XCTAssertTrue(approve.waitForExistence(timeout: 15))
        XCTAssertTrue(approve.isHittable)
        XCTAssertTrue(deny.isHittable)
        XCTAssertGreaterThanOrEqual(approve.frame.height, 60, "\(approve.frame)")
        XCTAssertTrue(approve.label.hasPrefix("Approve:"), approve.label)
        XCTAssertEqual(deny.label, "Deny")
        XCTAssertGreaterThan(approve.frame.midX, deny.frame.midX,
                             "right-handed: Approve belongs on the right")

        // The command it is about, verbatim and on screen.
        XCTAssertTrue(app.staticTexts["Hermes wants to run: rm -rf build"].exists)
    }

    /// The broader grants authorize commands nobody has read yet, so they are
    /// not on a single big tap.
    func testTheBroaderGrantsStillNeedAConfirmation() {
        let app = launchRun("run-6d04bb92c1")
        let more = app.buttons["approval-more-options"]
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        more.tap()
        let session = app.buttons["Allow for this session"]
        if !session.waitForExistence(timeout: 6) {
            // The list is still settling when the first tap lands often enough
            // to matter; one retry, then it really is a failure.
            more.tap()
        }
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Always allow"].exists)
        // And the command is restated where the decision is actually made.
        let restated = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'rm -rf build'")).firstMatch
        XCTAssertTrue(restated.exists)
        let cancel = app.buttons["Cancel"].exists ? app.buttons["Cancel"] : app.sheets.buttons["Cancel"]
        if cancel.exists { cancel.tap() }
    }

    func testAMacOnlyRequestHasNoButtonsAtAll() {
        let app = launchRun("run-7c15da3b02")
        let notice = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'answered in Iris on your Mac'")
        ).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["run-approve"].exists,
                       "nothing here may be approved from the phone")
        XCTAssertFalse(app.buttons["run-deny"].exists)
        XCTAssertFalse(app.buttons["approval-more-options"].exists)
    }

    /// Surfaced where the user already is: the main screen, in the same place
    /// as the proposal card.
    func testTheMainScreenShowsAWaitingApprovalWithItsOwnBigButtons() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiPreviewState", "approval"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Hermes is waiting for you"].waitForExistence(timeout: 15))
        let approve = app.buttons["approval-approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10))
        XCTAssertTrue(approve.isHittable)
        XCTAssertGreaterThan(approve.frame.midX, app.buttons["approval-deny"].frame.midX)
        // Never two sets of big buttons in one thumb zone.
        XCTAssertFalse(app.buttons["answer-yes"].exists)
    }

    /// A staged proposal owns the thumb zone; the approval stays reachable
    /// from the run and its notification.
    func testAStagedProposalTakesPrecedenceOverAWaitingApproval() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiPreviewState", "proposal"]
        app.launch()
        XCTAssertTrue(app.buttons["answer-yes"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["approval-approve"].exists)
    }
}
