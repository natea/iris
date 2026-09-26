//
//  RunStepDecodingTests.swift
//  IrisLivePrototypeTests
//
//  Decoding LINK_API.md §12's block. The millisecond cases exist because this
//  app once rendered a JavaScript timestamp as seconds and told the user a
//  step had started "in 56,661 years".
//

import XCTest
@testable import IrisLivePrototype

final class RunStepDecodingTests: XCTestCase {

    // MARK: Steps

    func testDecodesTheSpecsExampleStep() {
        let step = RunStep(json: [
            "id": "s1", "index": 1, "tool": "Terminal", "category": "code",
            "label": "osascript <<'EOF' tell applica…",
            "preview": "osascript <<'EOF' tell application \"Finder\"",
            "status": "done", "started_at": 1_758_240_301_000, "duration_ms": 1200
        ])
        XCTAssertEqual(step?.id, "s1")
        XCTAssertEqual(step?.index, 1)
        XCTAssertEqual(step?.tool, "Terminal")
        XCTAssertEqual(step?.category, .code)
        XCTAssertEqual(step?.status, .done)
        XCTAssertEqual(step?.durationMs, 1200)
        XCTAssertEqual(step?.durationText(), "1.2s")
    }

    func testStartedAtIsReadAsMillisecondsNotSeconds() {
        let step = RunStep(json: ["id": "s1", "status": "running", "started_at": 1_758_240_301_000])
        let date = try? XCTUnwrap(step?.startedAtDate)
        // 2025-09-19, not the year 57,706.
        let year = Calendar(identifier: .gregorian).component(.year, from: date ?? .distantFuture)
        XCTAssertEqual(year, 2025)
    }

    func testASecondsTimestampIsStillReadableIfOneEverArrives() {
        let step = RunStep(json: ["id": "s1", "status": "running", "started_at": 1_758_240_301])
        let date = try? XCTUnwrap(step?.startedAtDate)
        let year = Calendar(identifier: .gregorian).component(.year, from: date ?? .distantFuture)
        XCTAssertEqual(year, 2025)
    }

    func testMissingFieldsGetSensibleDefaults() {
        let step = RunStep(json: ["id": "s3"])
        XCTAssertEqual(step?.tool, "")
        XCTAssertEqual(step?.toolLabel, "Step")
        XCTAssertEqual(step?.label, "")
        XCTAssertEqual(step?.preview, "")
        XCTAssertNil(step?.durationMs)
        XCTAssertNil(step?.startedAtDate)
        // No status and no duration: it has not been said to be over.
        XCTAssertEqual(step?.status, .running)
        // Index recovered from the id rather than collapsing every step to 0.
        XCTAssertEqual(step?.index, 3)
    }

    func testAStepWithoutAnIdIsDropped() {
        XCTAssertNil(RunStep(json: ["index": 1, "tool": "Terminal"]))
        XCTAssertNil(RunStep(json: ["id": "", "index": 1]))
    }

    func testUnknownCategoryFallsBackToTheGenericIcon() {
        let step = RunStep(json: ["id": "s1", "category": "quantum", "status": "done", "duration_ms": 10])
        XCTAssertEqual(step?.category, .tool)
        XCTAssertEqual(step?.category.symbolName, "cpu")
    }

    func testEveryCategoryHasTheSpecsSymbol() {
        XCTAssertEqual(RunStepCategory.browser.symbolName, "globe")
        XCTAssertEqual(RunStepCategory.search.symbolName, "magnifyingglass")
        XCTAssertEqual(RunStepCategory.code.symbolName, "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(RunStepCategory.file.symbolName, "doc.text")
        XCTAssertEqual(RunStepCategory.tool.symbolName, "cpu")
    }

    func testUnknownStatusIsInferredFromDurationNotInvented() {
        let running = RunStep(json: ["id": "s1", "status": "weird"])
        XCTAssertEqual(running?.status, .running)
        let over = RunStep(json: ["id": "s2", "status": "weird", "duration_ms": 500])
        XCTAssertEqual(over?.status, .done)
    }

    func testPrettyToolName() {
        let step = RunStep(json: ["id": "s1", "tool": "web_search"])
        XCTAssertEqual(step?.toolLabel, "web search")
    }

    // MARK: The detail block

    func testDecodesTheDetailBlock() {
        let detail = LinkTaskDetail(json: [
            "run_id": "run-8f21", "status": "running", "task": "Goal: do the thing",
            "origin": "device:abc",
            "headline": "Running code", "step_count": 3, "steps_cursor": 5,
            "steps_complete": true, "steps_truncated": false,
            "steps": [
                ["id": "s1", "index": 1, "tool": "Terminal", "category": "code", "status": "done", "duration_ms": 1200],
                ["id": "s3", "index": 3, "tool": "web_search", "category": "search", "status": "running"]
            ]
        ], runId: "run-8f21", isDelta: true)

        XCTAssertEqual(detail.task.runId, "run-8f21")
        XCTAssertEqual(detail.task.status, "running")
        XCTAssertEqual(detail.headline, "Running code")
        XCTAssertEqual(detail.stepCount, 3)
        XCTAssertEqual(detail.stepsCursor, 5)
        XCTAssertTrue(detail.stepsComplete)
        XCTAssertFalse(detail.stepsTruncated)
        XCTAssertEqual(detail.steps.map(\.id), ["s1", "s3"])
        XCTAssertTrue(detail.isDelta)
    }

    func testADetailWithNoProgressBlockClaimsNothing() {
        let detail = LinkTaskDetail(json: ["run_id": "run-1", "status": "running"],
                                    runId: "run-1", isDelta: false)
        XCTAssertEqual(detail.headline, "")
        XCTAssertEqual(detail.stepCount, 0)
        XCTAssertTrue(detail.steps.isEmpty)
        // Absent is not "we can vouch for it".
        XCTAssertFalse(detail.stepsComplete)
    }

    func testListEntryCarriesHeadlineAndStepCount() {
        let task = LinkTask(json: [
            "run_id": "run-1", "task": "t", "status": "running", "origin": "desktop",
            "created_at": 1_758_240_000_000, "updated_at": 1_758_240_300_000,
            "headline": "Running code", "step_count": 7
        ])
        XCTAssertEqual(task?.headline, "Running code")
        XCTAssertEqual(task?.stepCount, 7)
    }

    func testListEntryWithoutTheProgressFieldsStillDecodes() {
        let task = LinkTask(json: ["run_id": "run-1", "status": "running"])
        XCTAssertEqual(task?.headline, "")
        XCTAssertEqual(task?.stepCount, 0)
    }

    // MARK: Durations

    func testDurationFormatMatchesTheDesktopThenDegradesGracefully() {
        XCTAssertEqual(RunStepFormat.duration(seconds: 1.2), "1.2s")
        XCTAssertEqual(RunStepFormat.duration(seconds: 0), "0.0s")
        XCTAssertEqual(RunStepFormat.duration(seconds: 9.94), "9.9s")
        XCTAssertEqual(RunStepFormat.duration(seconds: 48), "48s")
        XCTAssertEqual(RunStepFormat.duration(seconds: 59.4), "59s")
        XCTAssertEqual(RunStepFormat.duration(seconds: 125), "2m 05s")
        XCTAssertEqual(RunStepFormat.duration(seconds: 3600), "60m 00s")
        XCTAssertEqual(RunStepFormat.duration(seconds: -5), "0.0s")
    }

    func testARunningStepTicksFromItsStartTime() {
        let started = Date().addingTimeInterval(-12)
        let step = RunStep(id: "s1", index: 1, tool: "Terminal", category: .code,
                           status: .running, startedAtMs: started.timeIntervalSince1970 * 1000)
        XCTAssertEqual(step.durationText(now: Date()), "12s")
    }

    func testARunningStepWithNoStartTimeShowsNoDuration() {
        let step = RunStep(id: "s1", index: 1, tool: "Terminal", category: .code, status: .running)
        XCTAssertNil(step.durationText())
    }

    func testSpokenDurationForVoiceOver() {
        XCTAssertEqual(RunStepFormat.spokenDuration(seconds: 1), "1 second")
        XCTAssertEqual(RunStepFormat.spokenDuration(seconds: 12), "12 seconds")
        XCTAssertEqual(RunStepFormat.spokenDuration(seconds: 60), "1 minute")
        XCTAssertEqual(RunStepFormat.spokenDuration(seconds: 125), "2 minutes 5 seconds")
    }
}
