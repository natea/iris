//
//  ToolRouterTests.swift
//
//  The tool results the model sees are a contract, not an implementation
//  detail: LINK_API.md §5 fixes the keys AND the `instructions` wording,
//  because the model's next move is decided by them. These tests compare
//  against that document.
//

import XCTest
@testable import IrisLivePrototype

enum TestFailure: Error { case noResponse }

/// `XCTUnwrap` takes an autoclosure, which cannot contain `await`. This does
/// the same job for a tool response.
func requireResponse(
    _ value: [String: Any]?,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> [String: Any] {
    guard let value else {
        XCTFail("the tool returned no response", file: file, line: line)
        throw TestFailure.noResponse
    }
    return value
}

final class ToolRouterTests: XCTestCase {

    private func makeRouter(_ link: FakeLinkService, session: String = "sess-1") -> ToolRouter {
        // No settle window in tests: the race it covers cannot happen here.
        ToolRouter(link: link, userName: "Nate", sessionId: session,
                   settleInterval: 0, settleTimeout: 0)
    }

    private func call(_ name: String, _ args: [String: Any] = [:], id: String = "call-1") -> LiveToolCall {
        LiveToolCall(id: id, name: name, args: args)
    }

    // MARK: 5.1 check_hermes_status

    func testCheckStatusReachable() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let response = try requireResponse(await router.handle(call("check_hermes_status")))
        XCTAssertEqual(response["reachable"] as? Bool, true)
        XCTAssertEqual((response["health"] as? [String: Any])?["transport"] as? String, "iris_link")
    }

    func testCheckStatusNamesWhichSideIsDown() async throws {
        let link = FakeLinkService()
        await link.setStatusResult(.success(LinkStatus(
            deviceId: "d1", deviceName: "Test", hermesReachable: false,
            userName: "Nate", liveModel: "m", voice: "v", accent: "")))
        var response = try requireResponse(await makeRouter(link).handle(call("check_hermes_status")))
        XCTAssertEqual(response["reachable"] as? Bool, false)
        XCTAssertEqual(response["error"] as? String, "Hermes is not reachable from the Mac.")

        await link.setStatusResult(.failure(.unreachable("timed out")))
        response = try requireResponse(await makeRouter(link).handle(call("check_hermes_status")))
        XCTAssertEqual(response["reachable"] as? Bool, false)
        XCTAssertEqual(response["error"] as? String, "The Mac running Iris is not reachable (timed out).")
    }

    // MARK: 5.2 propose_hermes_task

    func testProposeFormatsTheDesktopsBriefAndReturnsTheContractsInstructions() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let response = try requireResponse(await router.handle(call("propose_hermes_task", [
            "goal": "Summarize the Q3 revenue deck",
            "context": "The deck is at ~/Docs/q3.key",
            "constraints": ["Finish before 5pm", "Do not email anyone"],
            "acceptance_criteria": ["A one-page summary exists"],
            "output_format": "Markdown",
            "urgency": "high",
        ])))
        XCTAssertEqual(response["status"] as? String, "proposed")
        let proposalId = try XCTUnwrap(response["proposal_id"] as? String)
        XCTAssertFalse(proposalId.isEmpty)
        XCTAssertEqual(response["task"] as? String, """
        Goal:
        Summarize the Q3 revenue deck

        User-provided context:
        The deck is at ~/Docs/q3.key

        Constraints:
        - Finish before 5pm
        - Do not email anyone

        Acceptance criteria:
        - A one-page summary exists

        Expected output:
        Markdown
        """)
        let instructions = try XCTUnwrap(response["instructions"] as? String)
        XCTAssertEqual(instructions, [
            "Now read this exact brief back to Nate in one or two short sentences, ask \"Should I send this to Hermes?\", and END YOUR TURN.",
            "Do NOT call submit_hermes_task yet — it will be rejected until they answer.",
            "Interpret Nate's next response by meaning, not by matching specific words. If they clearly authorize sending, submit proposal_id \"\(proposalId)\". If they decline, call discard_hermes_proposal with that proposal_id. If they change any detail, call propose_hermes_task again and read back the replacement proposal. If their intent is ambiguous, ask one short natural clarification.",
        ].joined(separator: " "))
    }

    func testProposeWithNoGoalIsAnError() async throws {
        let router = makeRouter(FakeLinkService())
        let response = try requireResponse(await router.handle(call("propose_hermes_task", ["context": "no goal"])))
        XCTAssertEqual(response["status"] as? String, "error")
        XCTAssertEqual(response["error"] as? String, "A complete task brief is required.")
    }

    // MARK: 5.3 submit_hermes_task

    func testSubmitInTheSameTurnIsBlockedAndNothingIsDispatched() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let proposed = try requireResponse(await router.handle(call("propose_hermes_task", ["goal": "Do the thing"])))
        let proposalId = try XCTUnwrap(proposed["proposal_id"] as? String)

        let blocked = try requireResponse(await router.handle(call("submit_hermes_task", ["proposal_id": proposalId])))
        XCTAssertEqual(blocked["status"] as? String, "blocked")
        XCTAssertEqual(blocked["error"] as? String,
                       "REJECTED: no distinct response from Nate was observed after the proposal read-back.")
        XCTAssertEqual(blocked["active_proposal_id"] as? String, proposalId)
        XCTAssertEqual(blocked["instructions"] as? String,
                       "Keep the same proposal staged, end your turn, and wait for the user's response. If their response was not captured, ask one brief natural clarification. Never demand specific confirmation wording.")
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 0, "no work may reach the agent without a user turn")
    }

    func testConfirmedSubmitDispatchesTheExactStagedBrief() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let proposed = try requireResponse(await router.handle(call("propose_hermes_task", [
            "goal": "Count the files in ~/Downloads",
            "urgency": "low",
        ])))
        let proposalId = try XCTUnwrap(proposed["proposal_id"] as? String)
        let brief = try XCTUnwrap(proposed["task"] as? String)

        await router.modelTurnComplete()
        await router.userTurnObserved("Yes, send it.")

        let started = try requireResponse(await router.handle(call("submit_hermes_task", ["proposal_id": proposalId])))
        XCTAssertEqual(started["status"] as? String, "started")
        XCTAssertEqual(started["run_id"] as? String, "run-1")
        XCTAssertEqual(started["origin"] as? String, "device:d1")
        XCTAssertEqual(started["message"] as? String, "Hermes has started the task.")
        XCTAssertEqual(started["instructions"] as? String,
                       "Say ONE short acknowledgement (e.g. 'On it — Hermes is handling that now.'). The task has only STARTED: you have NO result yet. Do not describe, predict, or summarize any outcome until SYSTEM_EVENT_HERMES_COMPLETE arrives or get_hermes_task_status returns a terminal status.")

        let dispatch = await link.lastDispatch()
        XCTAssertEqual(dispatch, .init(task: brief, urgency: "low"))
    }

    func testAFailedDispatchIsReportedHonestly() async throws {
        let link = FakeLinkService()
        await link.setDispatchResult(.failure(.agentUnreachable("")))
        let router = makeRouter(link)
        let proposed = try requireResponse(await router.handle(call("propose_hermes_task", ["goal": "Do it"])))
        let proposalId = try XCTUnwrap(proposed["proposal_id"] as? String)
        await router.modelTurnComplete()
        await router.userTurnObserved("Go ahead.")

        let response = try requireResponse(await router.handle(call("submit_hermes_task", ["proposal_id": proposalId])))
        XCTAssertEqual(response["status"] as? String, "error")
        XCTAssertEqual(response["error"] as? String, "agent_unreachable")
        XCTAssertEqual(response["instructions"] as? String,
                       "Say the task could not be sent and why. Do not claim Hermes is working on it.")

        // The proposal was consumed: the same id must not dispatch later.
        let retry = try requireResponse(await router.handle(call("submit_hermes_task", ["proposal_id": proposalId])))
        XCTAssertEqual(retry["status"] as? String, "blocked")
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 1)
    }

    func testACancelledSubmitNeverReachesDispatch() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let proposed = try requireResponse(await router.handle(call("propose_hermes_task", ["goal": "Do it"])))
        let proposalId = try XCTUnwrap(proposed["proposal_id"] as? String)
        await router.modelTurnComplete()
        await router.userTurnObserved("Yes.")
        await router.cancel(ids: ["call-9"])
        let response = await router.handle(call("submit_hermes_task", ["proposal_id": proposalId], id: "call-9"))
        XCTAssertNil(response, "a cancelled call's result must not be sent")
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: 5.4 discard_hermes_proposal

    func testDiscardAndItsBlockedShape() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let proposed = try requireResponse(await router.handle(call("propose_hermes_task", ["goal": "Do it"])))
        let proposalId = try XCTUnwrap(proposed["proposal_id"] as? String)

        let wrong = try requireResponse(await router.handle(call("discard_hermes_proposal", ["proposal_id": "nope"])))
        XCTAssertEqual(wrong["status"] as? String, "blocked")
        XCTAssertEqual(wrong["error"] as? String,
                       "Could not discard the staged Hermes proposal: proposal_mismatch.")
        XCTAssertEqual(wrong["active_proposal_id"] as? String, proposalId)
        XCTAssertEqual(wrong["instructions"] as? String,
                       "Do not claim that a different proposal was discarded.")

        let discarded = try requireResponse(await router.handle(call("discard_hermes_proposal", ["proposal_id": proposalId])))
        XCTAssertEqual(discarded["status"] as? String, "discarded")
        XCTAssertEqual(discarded["proposal_id"] as? String, proposalId)
        XCTAssertEqual(discarded["instructions"] as? String,
                       "Acknowledge the decline briefly. Do not send this proposal to Hermes.")
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 0, "a decline dispatches nothing")

        let after = try requireResponse(await router.handle(call("discard_hermes_proposal", ["proposal_id": proposalId])))
        XCTAssertEqual(after["error"] as? String,
                       "Could not discard the staged Hermes proposal: no_proposal.")
        XCTAssertTrue(after["active_proposal_id"] is NSNull)
    }

    // MARK: 5.5 get_hermes_task_status

    func testStatusShapes() async throws {
        let link = FakeLinkService()
        await link.setStatus(.success(LinkTaskStatus(runId: "r1", status: "running")), for: "r1")
        await link.setStatus(.success(LinkTaskStatus(runId: "r2", status: "completed", output: "42 files")), for: "r2")
        await link.setStatus(.failure(.taskUnknown), for: "r3")
        let router = makeRouter(link)

        let running = try requireResponse(await router.handle(call("get_hermes_task_status", ["run_id": "r1"])))
        XCTAssertEqual(running["status"] as? String, "running")
        XCTAssertEqual(running["run_id"] as? String, "r1")
        XCTAssertEqual(running["instructions"] as? String,
                       "The run is STILL IN PROGRESS. There is NO result yet. Tell the user it is still working and stop there — do not guess, predict, or invent any findings. You will receive SYSTEM_EVENT_HERMES_COMPLETE when it finishes.")
        XCTAssertNil(running["output"], "a running run must carry no output at all")

        let done = try requireResponse(await router.handle(call("get_hermes_task_status", ["run_id": "r2"])))
        XCTAssertEqual(done["status"] as? String, "completed")
        XCTAssertEqual(done["output"] as? String, "42 files")
        XCTAssertEqual(done["instructions"] as? String,
                       "The run is finished. Report ONLY what is in `output` above — nothing else.")

        let broken = try requireResponse(await router.handle(call("get_hermes_task_status", ["run_id": "r3"])))
        XCTAssertEqual(broken["status"] as? String, "error")
        XCTAssertEqual(broken["run_id"] as? String, "r3")
        XCTAssertEqual(broken["instructions"] as? String,
                       "You could not fetch the status. Say exactly that. Do not make up a status or a result.")
    }

    func testDesktopReportedStatusErrorIsRelayedNotGuessed() async throws {
        let link = FakeLinkService()
        await link.setStatus(.success(LinkTaskStatus(
            runId: "r9", status: "error", error: "Hermes returned 500")), for: "r9")
        let response = try requireResponse(await makeRouter(link).handle(call("get_hermes_task_status", ["run_id": "r9"])))
        XCTAssertEqual(response["status"] as? String, "error")
        XCTAssertEqual(response["error"] as? String, "Hermes returned 500")
    }

    // MARK: 5.6 stop_hermes_task

    func testStopShapes() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let ok = try requireResponse(await router.handle(call("stop_hermes_task", ["run_id": "r1"])))
        XCTAssertEqual(ok["status"] as? String, "stopping")
        XCTAssertEqual(ok["run_id"] as? String, "r1")

        await link.setStopResult(.failure(.taskUnknown))
        let bad = try requireResponse(await makeRouter(link).handle(call("stop_hermes_task", ["run_id": "r1"])))
        XCTAssertEqual(bad["status"] as? String, "error")
        XCTAssertNotNil(bad["error"])
    }

    // MARK: 5.7 approve_hermes_action

    func testApprovalIsRefusedLocallyUntilTheUserAnswersInTheirOwnTurn() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let refused = try requireResponse(await router.handle(call("approve_hermes_action", [
            "run_id": "r1", "choice": "once",
        ])))
        XCTAssertEqual(refused["status"] as? String, "blocked")
        XCTAssertEqual(refused["error"] as? String,
                       "The user's latest complete response does not explicitly authorize that approval choice.")
        XCTAssertEqual(refused["instructions"] as? String,
                       "Ask whether to allow this once, for this session, always, or deny it; end your turn and wait.")
        let calls = await link.approvalCalls()
        XCTAssertTrue(calls.isEmpty)

        await router.modelTurnComplete()
        await router.userTurnObserved("Just this once.")
        let resolved = try requireResponse(await router.handle(call("approve_hermes_action", [
            "run_id": "r1", "choice": "once",
        ])))
        XCTAssertEqual(resolved["status"] as? String, "resolved")
        XCTAssertEqual(resolved["choice"] as? String, "once")
        let after = await link.approvalCalls()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.decision, "once")
    }

    func testApprovalNotPendingIsStatedPlainly() async throws {
        let link = FakeLinkService()
        await link.setApprovalResult(.failure(.approvalNotPending))
        let router = makeRouter(link)
        await router.modelTurnComplete()
        await router.userTurnObserved("Deny it.")
        let response = try requireResponse(await router.handle(call("approve_hermes_action", [
            "run_id": "r1", "choice": "deny",
        ])))
        XCTAssertEqual(response["status"] as? String, "blocked")
        XCTAssertEqual(response["error"] as? String, "Hermes has no pending approval for this run.")
    }

    // MARK: 5.8 read_hermes_task_result

    func testReadResultShapes() async throws {
        let link = FakeLinkService()
        await link.setResult(.success(LinkTaskResult(
            runId: "r1", task: "Count files", status: "completed",
            output: "There are 42 files.",
            instructions: "Answer only from this complete Hermes result.")), for: "r1")
        await link.setResult(.failure(.taskNotFinished), for: "r2")
        await link.setResult(.failure(.resultUnavailable), for: "r3")
        let router = makeRouter(link)

        let ok = try requireResponse(await router.handle(call("read_hermes_task_result", ["run_id": "r1"])))
        XCTAssertEqual(ok["ok"] as? Bool, true)
        XCTAssertEqual(ok["output"] as? String, "There are 42 files.")
        XCTAssertEqual(ok["task"] as? String, "Count files")
        XCTAssertEqual(ok["status"] as? String, "completed")
        XCTAssertEqual(ok["instructions"] as? String, "Answer only from this complete Hermes result.")

        let unfinished = try requireResponse(await router.handle(call("read_hermes_task_result", ["run_id": "r2"])))
        XCTAssertEqual(unfinished["ok"] as? Bool, false)
        XCTAssertEqual(unfinished["error"] as? String, "That Hermes run has not finished.")
        XCTAssertEqual(unfinished["instructions"] as? String,
                       "Say it is still working; do not invent a result.")

        let gone = try requireResponse(await router.handle(call("read_hermes_task_result", ["run_id": "r3"])))
        XCTAssertEqual(gone["ok"] as? Bool, false)
        XCTAssertEqual(gone["error"] as? String, "The selected Hermes result could not be restored.")
        XCTAssertEqual(gone["instructions"] as? String,
                       "Say the result is unavailable; do not invent its contents.")
    }

    // MARK: Undeclared tools

    func testAnUndeclaredToolIsRefusedRatherThanFaked() async throws {
        let response = try requireResponse(await makeRouter(FakeLinkService()).handle(call("respond_hermes_interaction")))
        XCTAssertEqual(response["status"] as? String, "error")
        XCTAssertTrue((response["error"] as? String)?.contains("not available on the phone") == true)
    }

    // MARK: System events (LINK_API.md §7)

    func testSessionStartTemplate() {
        XCTAssertEqual(
            SystemEvent.sessionStart(userName: "Nate"),
            "SYSTEM_EVENT_SESSION_START: Greet Nate once in one short sentence, then ask what they have in mind. Do not report service status unless asked."
        )
    }

    func testHermesCompleteTemplate() {
        XCTAssertEqual(
            SystemEvent.hermesComplete(runId: "r1", status: "completed", output: "42 files", userName: "Nate"),
            """
            SYSTEM_EVENT_HERMES_COMPLETE
            run_id: r1
            status: completed
            instructions_to_iris:
            - Tell Nate Hermes has returned and summarize the authoritative result below in 1-3 sentences.
            - Preserve explicit counts, names, and quantities exactly; if unsure, omit them rather than infer.
            - Ask whether to review the details. Do not claim you performed Hermes's work.
            authoritative_hermes_result:
            42 files
            """
        )
    }

    func testHermesCompleteWithNoOutputAndAfterWaking() {
        let text = SystemEvent.hermesComplete(
            runId: "r2", status: "failed", output: "", userName: "Nate", wakingFromSleep: true)
        XCTAssertTrue(text.contains("- Iris was woken for this result. Deliver it directly without a greeting."))
        XCTAssertTrue(text.hasSuffix("authoritative_hermes_result:\n(Hermes returned no text output.)"))
        XCTAssertTrue(text.contains("status: failed"))
    }
}
