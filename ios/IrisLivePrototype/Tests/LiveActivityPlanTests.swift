//
//  LiveActivityPlanTests.swift
//
//  The start / update / end decisions, and the state they carry. All of it is
//  pure, which is the point: ActivityKit cannot be driven from a test bundle,
//  so if these rules lived inside the controller they would be checked only by
//  hand on a phone.
//
//  The rules under test are LINK_API.md §14.1 (ONE summary activity, never one
//  per run), §14.4 (who starts it and when) and §14.5 (the real terminal
//  status, and the 5 / 30 minute dismissal windows).
//

import XCTest
@testable import IrisLivePrototype

final class LiveActivityPlanTests: XCTestCase {

    private func run(
        _ id: String,
        task: String = "Deploy the site",
        status: String = "running",
        origin: String = "device:d1",
        updatedAt: Double = 1_700_000_000_000,
        headline: String = "Running code",
        stepCount: Int = 0,
        approval: PendingApproval? = nil
    ) -> LinkTask {
        LinkTask(
            runId: id, task: task, status: status, origin: origin,
            createdAt: updatedAt - 60_000, updatedAt: updatedAt,
            headline: headline, stepCount: stepCount, pendingApproval: approval
        )
    }

    private let approval = PendingApproval(
        requestId: "approval:9f3c",
        summary: "Hermes wants to run: rm -rf build",
        canApproveFromPhone: true
    )

    // MARK: Building the state

    func testTheStateSummarisesEveryActiveRunNotOnePerRun() throws {
        let state = try XCTUnwrap(LiveActivityPlan.activeState(runs: [
            run("run-1", task: "Deploy the site", updatedAt: 1_700_000_003_000),
            run("run-2", task: "Book a table", updatedAt: 1_700_000_002_000),
            run("run-3", task: "Summarize the numbers", updatedAt: 1_700_000_001_000),
            run("run-4", task: "Tidy the desk", updatedAt: 1_700_000_000_000),
            run("run-5", task: "Finished", status: "completed"),
        ]))
        XCTAssertEqual(state.activeRunCount, 4, "the count includes runs beyond the three listed")
        XCTAssertEqual(state.runs.count, 3, "§14.1 caps the list at three")
        XCTAssertEqual(state.runs.map(\.id), ["run-1", "run-2", "run-3"])
    }

    func testARunBlockedOnAHumanBecomesThePrimaryOneAndSetsTheFlag() throws {
        let state = try XCTUnwrap(LiveActivityPlan.activeState(runs: [
            run("run-newer", task: "Summarize the numbers", updatedAt: 1_700_000_900_000),
            run("run-waiting", task: "Deploy the site", updatedAt: 1_700_000_000_000, approval: approval),
        ]))
        XCTAssertEqual(state.status, "waiting")
        XCTAssertTrue(state.needsAttention)
        XCTAssertEqual(state.attentionSummary, "Hermes wants to run: rm -rf build")
        XCTAssertEqual(state.title, "Deploy the site")
        XCTAssertEqual(state.runs.first?.status, "waiting")
    }

    func testZeroStepsIsReportedAsUnknownRatherThanAsNoWork() throws {
        let state = try XCTUnwrap(LiveActivityPlan.activeState(runs: [run("run-1", stepCount: 0)]))
        XCTAssertFalse(state.stepsKnown)
        XCTAssertNil(state.stepText)

        let known = try XCTUnwrap(LiveActivityPlan.activeState(runs: [run("run-1", stepCount: 7)]))
        XCTAssertTrue(known.stepsKnown)
        XCTAssertEqual(known.stepText, "7 steps")
    }

    func testTimestampsAreConvertedFromTheDesktopsMilliseconds() throws {
        let state = try XCTUnwrap(LiveActivityPlan.activeState(
            runs: [run("run-1", updatedAt: 1_700_000_000_000)],
            now: Date(timeIntervalSince1970: 1_700_000_500)
        ))
        XCTAssertEqual(state.startedAt, 1_699_999_940, accuracy: 0.001)
        XCTAssertEqual(state.updatedAt, 1_700_000_500, accuracy: 0.001)
    }

    func testThereIsNoActiveStateWhenNothingIsActive() {
        XCTAssertNil(LiveActivityPlan.activeState(runs: []))
        XCTAssertNil(LiveActivityPlan.activeState(runs: [run("run-1", status: "completed")]))
    }

    // MARK: The real terminal status

    func testTheEndStateCarriesTheRealStatusWord() {
        let cases: [(String, String)] = [
            ("completed", "done"),
            ("failed", "failed"),
            ("error", "failed"),
            ("cancelled", "stopped"),
            ("canceled", "stopped"),
        ]
        for (desktop, expected) in cases {
            let state = LiveActivityPlan.endState(runs: [run("run-1", status: desktop)])
            XCTAssertEqual(state.status, expected, "\(desktop) must end as \(expected)")
            XCTAssertEqual(state.activeRunCount, 0)
            XCTAssertTrue(state.runs.isEmpty)
            XCTAssertFalse(state.stepsKnown)
        }
    }

    func testABadEndingStaysOnScreenLongerThanAGoodOne() {
        // §14.5: +5 minutes for `done`, +30 for `failed`/`stopped` — a bad
        // ending is the one you are most likely to have missed.
        XCTAssertEqual(LiveActivityPlan.dismissalDelay(for: .init(status: "done")), 5 * 60)
        XCTAssertEqual(LiveActivityPlan.dismissalDelay(for: .init(status: "failed")), 30 * 60)
        XCTAssertEqual(LiveActivityPlan.dismissalDelay(for: .init(status: "stopped")), 30 * 60)
    }

    // MARK: Deciding

    func testNothingHappensWhenThereIsNoActiveRunAndNoActivity() {
        let decision = LiveActivityPlan.decide(.init(runs: [run("run-1", status: "completed")], hasActivity: false))
        XCTAssertEqual(decision, .doNothing)
    }

    func testADeviceRunInTheForegroundStartsExactlyOneActivity() throws {
        let runs = [run("run-1"), run("run-2")]
        guard case .start(let state) = LiveActivityPlan.decide(.init(runs: runs, hasActivity: false)) else {
            return XCTFail("a device-origin run in the foreground must start the activity")
        }
        XCTAssertEqual(state.activeRunCount, 2)

        // And with the activity running, two more runs are still ONE activity.
        let next = LiveActivityPlan.decide(.init(runs: runs + [run("run-3")], hasActivity: true))
        guard case .update = next else { return XCTFail("a second run must update, never start a second activity") }
    }

    func testADesktopRunNeverConjuresAnActivity() {
        // §14.4: the Mac never starts an activity uninvited for its own work.
        let decision = LiveActivityPlan.decide(.init(
            runs: [run("run-1", origin: "desktop")], hasActivity: false))
        XCTAssertEqual(decision, .doNothing)
    }

    func testADesktopRunDoesAppearInAnActivityThatAlreadyExists() throws {
        guard case .update(let state, _) = LiveActivityPlan.decide(.init(
            runs: [run("run-1", origin: "desktop")], hasActivity: true)) else {
            return XCTFail("a desktop run must appear in an existing activity")
        }
        XCTAssertEqual(state.activeRunCount, 1)
    }

    func testTheAppDoesNotStartAnActivityFromTheBackground() {
        // §14.4: from the background the phone waits for push-to-start.
        let decision = LiveActivityPlan.decide(.init(
            runs: [run("run-1")], hasActivity: false, appIsActive: false))
        XCTAssertEqual(decision, .doNothing)
    }

    func testTheActivityEndsWhenTheLastRunFinishes() throws {
        guard case .end(let state) = LiveActivityPlan.decide(.init(
            runs: [run("run-1", status: "failed")], hasActivity: true)) else {
            return XCTFail("the last run finishing must end the activity")
        }
        XCTAssertEqual(state.status, "failed")
    }

    func testTurningItOffDoesNothingWhenNothingIsRunningAndEndsWhatIs() {
        XCTAssertEqual(
            LiveActivityPlan.decide(.init(runs: [run("run-1")], enabled: false, hasActivity: false)),
            .doNothing
        )
        guard case .end = LiveActivityPlan.decide(.init(runs: [run("run-1")], enabled: false, hasActivity: true))
        else { return XCTFail("an activity left running with the switch off must be ended") }
    }

    func testIOSHavingLiveActivitiesOffMeansNothingIsAttempted() {
        XCTAssertEqual(
            LiveActivityPlan.decide(.init(runs: [run("run-1")], systemAllows: false, hasActivity: false)),
            .doNothing
        )
    }

    func testTheAlertFiresOnlyOnTheTransitionIntoNeedingAHuman() {
        let waiting = [run("run-1", approval: approval)]
        guard case .update(_, let first) = LiveActivityPlan.decide(.init(
            runs: waiting, hasActivity: true, wasNeedingAttention: false)) else {
            return XCTFail("expected an update")
        }
        XCTAssertTrue(first, "the moment a run becomes blocked is worth interrupting for")

        guard case .update(_, let again) = LiveActivityPlan.decide(.init(
            runs: waiting, hasActivity: true, wasNeedingAttention: true)) else {
            return XCTFail("expected an update")
        }
        XCTAssertFalse(again, "a routine update about the same approval must not alert again")
    }

    // MARK: The truthfulness rules the views read off the state

    func testAnEmptyHeadlineFallsBackToTheStatusAndNotAGuess() {
        // §14.2 rule 2.
        XCTAssertEqual(
            IrisRunActivityAttributes.ContentState(status: "running", headline: "").headlineOrStatus,
            "Working")
        XCTAssertEqual(
            IrisRunActivityAttributes.ContentState(status: "waiting", headline: "").headlineOrStatus,
            "Waiting for you")
    }

    func testStepsUnknownRendersNothingRatherThanZeroSteps() {
        // §14.2 rule 3.
        let unknown = IrisRunActivityAttributes.ContentState(status: "running", stepCount: 0, stepsKnown: false)
        XCTAssertNil(unknown.stepText)
        let known = IrisRunActivityAttributes.ContentState(status: "running", stepCount: 1, stepsKnown: true)
        XCTAssertEqual(known.stepText, "1 step")
    }

    func testAnUnknownStatusWordIsNeverReadAsSuccess() {
        let state = IrisRunActivityAttributes.ContentState(status: "something-new")
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.phase.isTerminal)
    }

    func testEveryStateHasItsOwnIconSoColourIsNeverTheOnlySignal() {
        let phases: [IrisRunActivityAttributes.ContentState.Phase] =
            [.running, .waiting, .idle, .done, .failed, .stopped]
        XCTAssertEqual(Set(phases.map(IrisActivityLook.symbol(for:))).count, phases.count,
                       "two states share an icon")
        XCTAssertEqual(IrisActivityLook.label(for: .failed), "Couldn't finish",
                       "§14.2 rule 4: failed is not finished")
    }
}
