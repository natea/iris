import XCTest

/// The two screens this change adds, driven through real taps. A preview of a
/// view proves the layout; only a tap proves the control is reachable and that
/// the choice is still there after a relaunch.
///
/// Both run on DEBUG launch-argument fixtures (`-uiPreviewState`), so no Mac,
/// no token, no network and no audio is involved.
final class VoiceSettingsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// A SwiftUI List only builds the rows it is showing, so anything off
    /// screen does not exist until it is scrolled to — and scrolls past it
    /// again once it leaves. `swipeUp()` moves a whole screen at a time, which
    /// is enough to step straight over a row, so this drags about a third of a
    /// screen per step and checks after each one.
    private func reveal(
        _ element: XCUIElement,
        in app: XCUIApplication,
        up: Bool = false,
        steps: Int = 14
    ) -> Bool {
        if element.waitForExistence(timeout: 3) { return true }
        let fromY = up ? 0.35 : 0.75
        let toY = up ? 0.75 : 0.45
        for _ in 0..<steps {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fromY))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: toY))
            start.press(forDuration: 0.05, thenDragTo: end)
            if element.exists { return true }
        }
        return element.exists
    }

    private func launchSettings() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiPreviewState", "voices", "-uiPreviewScreen", "settings"]
        app.launch()
        return app
    }

    func testTheVoiceSectionListsTheMacsCatalogue() {
        let app = launchSettings()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))

        // §13.3: "<name> · <style>", straight from GET /link/status.
        XCTAssertTrue(reveal(app.buttons["voice-mac-default"], in: app),
                      "the Mac's default is a choice of its own")
        XCTAssertTrue(app.staticTexts["Zephyr · Bright"].exists)
        XCTAssertTrue(reveal(app.staticTexts["Algenib · Gravelly"], in: app))
        // Each voice can be heard before it is chosen.
        XCTAssertTrue(app.buttons["preview-Algenib"].exists)
        // The accent is read-only. It is a LabeledContent, so the accent
        // itself may be the element's value rather than a text of its own.
        let accent = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                        "British (RP, London)", "British (RP, London)")
        ).firstMatch
        XCTAssertTrue(reveal(accent, in: app), "the configured accent must be shown")
    }

    func testChoosingAVoicePersistsAcrossALaunch() {
        var app = launchSettings()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let algenib = app.buttons["voice-Algenib"]
        XCTAssertTrue(reveal(algenib, in: app))
        algenib.tap()
        XCTAssertEqual(algenib.value as? String, "Selected")
        XCTAssertEqual(app.buttons["voice-mac-default"].value as? String, "Not selected")
        app.terminate()

        // The choice lives in UserDefaults (§13.4), so it has to survive this.
        app = launchSettings()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let again = app.buttons["voice-Algenib"]
        XCTAssertTrue(reveal(again, in: app))
        XCTAssertEqual(again.value as? String, "Selected", "the chosen voice must survive a relaunch")

        // Leave the simulator as it was found. The default is above Algenib,
        // so this scrolls back up rather than further down.
        let macDefault = app.buttons["voice-mac-default"]
        XCTAssertTrue(reveal(macDefault, in: app, up: true))
        macDefault.tap()
        XCTAssertEqual(macDefault.value as? String, "Selected")
    }

    /// Tapping ▶ has to reach the preview, not the row's other button. The
    /// fixture has no Mac behind it, so a preview that really started ends in
    /// the inline failure line; a tap that went nowhere leaves nothing at all.
    func testTappingPreviewStartsAPreviewAndLeavesTheChoiceAlone() {
        let app = launchSettings()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let play = app.buttons["preview-Puck"]
        XCTAssertTrue(reveal(play, in: app))
        XCTAssertTrue(play.isEnabled, "no conversation is live, so the preview must be on offer")
        let before = app.buttons["voice-Puck"].value as? String
        play.tap()

        let failure = app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH 'Puck: '")
        ).firstMatch
        // The line sits under the last voice, and a List builds no row it is
        // not showing.
        XCTAssertTrue(reveal(failure, in: app), "the tap never reached the preview")
        XCTAssertEqual(app.buttons["voice-Puck"].value as? String, before,
                       "hearing a voice must not choose it")
    }

    /// §13.2 — the user must not think the voice they just picked applies to
    /// the conversation they are in.
    func testTheSectionSaysANewVoiceAppliesNextTime() {
        let app = launchSettings()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15))
        let footer = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'applies from your next conversation'")
        ).firstMatch
        XCTAssertTrue(reveal(footer, in: app))
    }
}

final class PendingApprovalUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launchRun(_ runId: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiPreviewState", "approval",
            "-uiPreviewScreen", "runs",
            "-uiPreviewRun", runId,
        ]
        app.launch()
        return app
    }

    func testARunWaitingOnTheUserShowsTheCardAndConfirms() {
        let app = launchRun("run-6d04bb92c1")

        let card = app.staticTexts["Hermes wants to run: rm -rf build"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the summary must be on screen, verbatim")

        // The single-tap answers are the big ones in the thumb zone.
        XCTAssertTrue(app.buttons["run-approve"].exists)
        XCTAssertTrue(app.buttons["run-deny"].exists)

        // The BROADER grants keep their confirmation, because they authorize
        // commands that do not exist yet: nothing is sent by this first tap,
        // it opens a dialog that restates the command.
        let more = app.buttons["approval-more-options"]
        XCTAssertTrue(more.exists)
        more.tap()
        if !app.buttons["Allow once"].waitForExistence(timeout: 6) { more.tap() }
        XCTAssertTrue(app.buttons["Allow once"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Always allow"].exists)
        XCTAssertTrue(app.buttons["Allow for this session"].exists)
        // The confirmation restates the command, so nobody approves something
        // they have not just read.
        let restated = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'rm -rf build'")).firstMatch
        XCTAssertTrue(restated.exists, "the dialog must repeat the exact command")

        // Dismissing leaves the card exactly where it was. (The fixture has no
        // Link service behind it, so no decision can be sent from here.)
        let cancel = app.buttons["Cancel"].exists
            ? app.buttons["Cancel"]
            : app.sheets.buttons["Cancel"]
        if cancel.exists {
            cancel.tap()
        } else {
            app.buttons["Allow once"].tap()
        }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    /// §11.5 — when Link cannot carry the answer there are no buttons at all,
    /// only the truth about where it has to be answered.
    func testAMacOnlyPromptOffersNoButtons() {
        let app = launchRun("run-7c15da3b02")

        let notice = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'answered in Iris on your Mac'")
        ).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["run-approve"].exists, "nothing here may be approved from the phone")
        XCTAssertFalse(app.buttons["run-deny"].exists)
    }

    /// The marker has to be in the list too: a run that needs an answer must
    /// not be something only a notification could have told you.
    func testTheRunsListMarksARunThatNeedsYou() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiPreviewState", "approval", "-uiPreviewScreen", "runs"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Runs"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Hermes is waiting for you"].waitForExistence(timeout: 10))
    }
}
