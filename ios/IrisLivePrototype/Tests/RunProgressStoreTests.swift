//
//  RunProgressStoreTests.swift
//  IrisLivePrototypeTests
//
//  The delta-merge rules of LINK_API.md §12.3 and the honesty rules of §12.4,
//  pinned so a refactor cannot quietly start inventing progress.
//

import XCTest
@testable import IrisLivePrototype

final class RunProgressStoreTests: XCTestCase {

    // MARK: Helpers

    private func step(
        _ id: String, _ index: Int, status: RunStepStatus = .done,
        tool: String = "Terminal", category: RunStepCategory = .code, durationMs: Int? = 1200
    ) -> RunStep {
        RunStep(id: id, index: index, tool: tool, category: category,
                label: "l\(index)", preview: "p\(index)", status: status,
                startedAtMs: 1_758_240_300_000, durationMs: durationMs)
    }

    private func detail(
        steps: [RunStep], cursor: Int, isDelta: Bool,
        headline: String = "Running code", count: Int? = nil,
        complete: Bool = true, truncated: Bool = false, status: String = "running"
    ) -> LinkTaskDetail {
        LinkTaskDetail(
            task: LinkTaskStatus(runId: "run-1", status: status),
            headline: headline, stepCount: count ?? steps.count, stepsCursor: cursor,
            stepsComplete: complete, stepsTruncated: truncated, steps: steps, isDelta: isDelta
        )
    }

    // MARK: First load

    func testFirstFullLoadTakesEverything() {
        var store = RunProgressStore()
        XCTAssertNil(store.nextStepsSince, "first load must fetch the whole list")

        store.apply(detail(steps: [step("s1", 1), step("s2", 2)], cursor: 2, isDelta: false))

        XCTAssertEqual(store.steps.map(\.id), ["s1", "s2"])
        XCTAssertEqual(store.headline, "Running code")
        XCTAssertEqual(store.stepCount, 2)
        XCTAssertEqual(store.nextStepsSince, 2)
        XCTAssertFalse(store.isKnownIncomplete)
    }

    // MARK: Deltas

    func testDeltaAppendsNewStepsAndKeepsOrderByIndex() {
        var store = RunProgressStore()
        store.apply(detail(steps: [step("s1", 1), step("s2", 2)], cursor: 2, isDelta: false))

        // Arrives out of order; index is what orders the list.
        store.apply(detail(steps: [step("s4", 4), step("s3", 3)], cursor: 4, isDelta: true, count: 4))

        XCTAssertEqual(store.steps.map(\.id), ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(store.steps.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(store.nextStepsSince, 4)
    }

    func testDeltaReplacesAStepThatMerelyFinished() {
        var store = RunProgressStore()
        store.apply(detail(
            steps: [step("s1", 1), step("s2", 2, status: .running, durationMs: nil)],
            cursor: 2, isDelta: false
        ))
        XCTAssertEqual(store.steps.last?.status, .running)
        XCTAssertNil(store.steps.last?.durationMs)

        // §12.3: "a step that merely finished comes back again".
        store.apply(detail(
            steps: [step("s2", 2, status: .done, durationMs: 4800)],
            cursor: 3, isDelta: true, count: 2
        ))

        XCTAssertEqual(store.steps.count, 2, "the finished step must replace, not duplicate")
        XCTAssertEqual(store.steps.last?.status, .done)
        XCTAssertEqual(store.steps.last?.durationMs, 4800)
    }

    func testDeltaFailureIsCarriedThrough() {
        var store = RunProgressStore()
        store.apply(detail(steps: [step("s1", 1, status: .running, durationMs: nil)], cursor: 1, isDelta: false))
        store.apply(detail(steps: [step("s1", 1, status: .failed, durationMs: 300)], cursor: 2, isDelta: true, count: 1))
        XCTAssertEqual(store.steps.map(\.status), [.failed])
    }

    func testCountsAndHeadlineAlwaysDescribeTheWholeRun() {
        var store = RunProgressStore()
        store.apply(detail(steps: [step("s1", 1)], cursor: 1, isDelta: false))
        // A delta carrying one step, but the run has seven.
        store.apply(detail(steps: [step("s7", 7)], cursor: 7, isDelta: true,
                           headline: "Searching example.com", count: 7))

        XCTAssertEqual(store.stepCount, 7)
        XCTAssertEqual(store.headline, "Searching example.com")
        XCTAssertEqual(store.stepCountText, "7 steps")
        XCTAssertEqual(store.steps.count, 2, "only what the deltas carried is held")
    }

    func testSingularStepCountText() {
        var store = RunProgressStore()
        store.apply(detail(steps: [step("s1", 1)], cursor: 1, isDelta: false))
        XCTAssertEqual(store.stepCountText, "1 step")
    }

    // MARK: Cursor handling

    func testRequireFullResyncDropsTheCursorForOnePoll() {
        var store = RunProgressStore()
        store.apply(detail(steps: [step("s1", 1)], cursor: 1, isDelta: false))
        XCTAssertEqual(store.nextStepsSince, 1)

        store.requireFullResync()
        XCTAssertNil(store.nextStepsSince, "a resync must ask for the whole list")

        store.apply(detail(steps: [step("s1", 1), step("s2", 2)], cursor: 2, isDelta: false))
        XCTAssertEqual(store.nextStepsSince, 2, "and then go back to deltas")
        XCTAssertEqual(store.steps.map(\.id), ["s1", "s2"])
    }

    func testAFullResponseReplacesRatherThanMerges() {
        var store = RunProgressStore()
        store.apply(detail(steps: [step("s1", 1), step("s2", 2), step("s3", 3)], cursor: 3, isDelta: false))
        // The 60-step bound evicted the first two on the Mac.
        store.apply(detail(steps: [step("s3", 3)], cursor: 3, isDelta: false, count: 1, truncated: true))
        XCTAssertEqual(store.steps.map(\.id), ["s3"])
    }

    func testARewoundCursorTriggersAResyncInsteadOfMerging() {
        var store = RunProgressStore()
        store.apply(detail(steps: [step("s1", 1), step("s2", 2)], cursor: 9, isDelta: false))

        // Iris restarted: its per-run counter went back to the beginning.
        store.apply(detail(steps: [step("s1", 1)], cursor: 1, isDelta: true, count: 1))

        XCTAssertEqual(store.steps.map(\.id), ["s1"], "stale steps from a previous life are dropped")
        XCTAssertEqual(store.cursor, 1)
    }

    // MARK: Honesty

    func testEmptyAndIncompleteSaysSoInTheSpecsWording() {
        var store = RunProgressStore()
        store.apply(detail(steps: [], cursor: 0, isDelta: false, headline: "", count: 0, complete: false))

        XCTAssertTrue(store.steps.isEmpty)
        XCTAssertTrue(store.isKnownIncomplete)
        XCTAssertEqual(
            store.incompleteNotice(isActive: true),
            "Iris doesn't have the step history for this run — it's still working."
        )
        XCTAssertEqual(
            store.incompleteNotice(isActive: false),
            "Iris doesn't have the step history for this run."
        )
    }

    func testTruncationIsAdmitted() {
        var store = RunProgressStore()
        store.apply(detail(steps: [step("s59", 59), step("s60", 60)], cursor: 60, isDelta: false,
                           count: 60, complete: false, truncated: true))
        XCTAssertEqual(
            store.incompleteNotice(isActive: true),
            "Older steps were dropped on the Mac — this is the most recent 2."
        )
    }

    func testPartialHistoryIsAdmitted() {
        var store = RunProgressStore()
        store.apply(detail(steps: [step("s1", 1)], cursor: 1, isDelta: false, complete: false))
        XCTAssertEqual(
            store.incompleteNotice(isActive: true),
            "This may not be the full step history — Iris can't vouch for what came before."
        )
    }

    func testACompleteListSaysNothing() {
        var store = RunProgressStore()
        store.apply(detail(steps: [step("s1", 1)], cursor: 1, isDelta: false, complete: true))
        XCTAssertNil(store.incompleteNotice(isActive: true))
        XCTAssertFalse(store.isKnownIncomplete)
    }

    func testAnUntouchedStoreClaimsNothing() {
        let store = RunProgressStore()
        XCTAssertFalse(store.isKnownIncomplete)
        XCTAssertNil(store.incompleteNotice(isActive: true))
        XCTAssertEqual(store.headline, "")
        XCTAssertTrue(store.steps.isEmpty)
    }
}
