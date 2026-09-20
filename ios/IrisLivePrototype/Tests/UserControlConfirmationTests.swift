//
//  UserControlConfirmationTests.swift
//
//  The spec's "Confirmation by an explicit control": a tap counts as the
//  user's answer only when it is a deliberate action on a trusted surface
//  showing the COMPLETE brief; the model can never trigger it; Yes dispatches
//  exactly the staged brief ONCE and says so; No discards; "Let me explain"
//  leaves it staged and unsent; a tap for a brief that is no longer staged
//  dispatches nothing.
//
//  Everything here is pure: a fake Link service and a fake transport, so each
//  assertion is about the rule rather than about a socket or a screen.
//

import XCTest
@testable import IrisLivePrototype

final class UserControlConfirmationTests: XCTestCase {

    // MARK: Helpers

    private func makeRouter(_ link: FakeLinkService, session: String = "sess-1") -> ToolRouter {
        ToolRouter(link: link, userName: "Nate", sessionId: session,
                   settleInterval: 0, settleTimeout: 0)
    }

    private func stage(
        _ router: ToolRouter,
        goal: String = "Count the files in Downloads",
        id: String = "call-1"
    ) async throws -> String {
        let proposed = await router.handle(
            LiveToolCall(id: id, name: "propose_hermes_task", args: ["goal": goal]))
        return try XCTUnwrap(proposed?["proposal_id"] as? String)
    }

    /// A coordinator on fakes, with the settle window off.
    private func makeCoordinator(
        _ link: FakeLinkService, _ transport: FakeTransport
    ) -> SessionCoordinator {
        SessionCoordinator(link: link, transport: transport, userName: "Nate",
                           settleInterval: 0.01, settleTimeout: 0.02)
    }

    // MARK: The tap itself

    func testATapConfirmsDuringTheReadBackAndAfterIt() async throws {
        // DURING: the model is still speaking the brief. The voice path would
        // refuse this (no user turn yet) and is meant to — but the complete
        // brief is on screen, which is what a tap confirms.
        let duringLink = FakeLinkService()
        let during = makeRouter(duringLink)
        let duringId = try await stage(during)
        let midReadback = await during.confirmByUserControl(proposalId: duringId)
        guard case .dispatched(let runId, let task) = midReadback else {
            return XCTFail("a tap during the read-back must confirm: \(midReadback)")
        }
        XCTAssertEqual(runId, "run-1")
        XCTAssertTrue(task.hasPrefix("Goal:"))
        let duringCount = await duringLink.dispatchCount()
        XCTAssertEqual(duringCount, 1)

        // AFTER: read-back finished, no spoken answer, tap instead.
        let afterLink = FakeLinkService()
        let after = makeRouter(afterLink)
        let afterId = try await stage(after)
        await after.modelTurnComplete()
        let outcome = await after.confirmByUserControl(proposalId: afterId)
        guard case .dispatched = outcome else {
            return XCTFail("a tap after the read-back must confirm: \(outcome)")
        }
        let afterCount = await afterLink.dispatchCount()
        XCTAssertEqual(afterCount, 1)
    }

    func testTheBriefThatIsSentIsTheBriefThatWasStaged() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let id = try await stage(router, goal: "Reconcile the September invoices")
        _ = await router.confirmByUserControl(proposalId: id)
        let sent = await link.lastDispatch()
        XCTAssertEqual(sent?.task, "Goal:\nReconcile the September invoices")
        XCTAssertEqual(sent?.urgency, "normal")
    }

    func testAWrongOrStaleProposalIdDispatchesNothing() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let staged = try await stage(router)

        let wrong = await router.confirmByUserControl(proposalId: "not-the-staged-one")
        XCTAssertEqual(wrong, .stale)
        let empty = await router.confirmByUserControl(proposalId: "")
        XCTAssertEqual(empty, .stale)
        var count = await link.dispatchCount()
        XCTAssertEqual(count, 0, "nothing may reach Hermes")

        // And the real one still works, so the refusal was about identity.
        let right = await router.confirmByUserControl(proposalId: staged)
        guard case .dispatched = right else { return XCTFail("\(right)") }
        count = await link.dispatchCount()
        XCTAssertEqual(count, 1)
    }

    func testAReplacedProposalCannotBeConfirmedByTheOldId() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let first = try await stage(router, goal: "Delete the build folder")
        let second = try await stage(router, goal: "Archive the build folder", id: "call-2")
        XCTAssertNotEqual(first, second)

        let stale = await router.confirmByUserControl(proposalId: first)
        XCTAssertEqual(stale, .stale, "the controls act only on the brief now shown")
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 0)

        // The replacement is confirmable, and it is the replacement that goes.
        let fresh = await router.confirmByUserControl(proposalId: second)
        guard case .dispatched = fresh else { return XCTFail("\(fresh)") }
        let sent = await link.lastDispatch()
        XCTAssertEqual(sent?.task, "Goal:\nArchive the build folder")
    }

    // MARK: Exactly once

    func testADoubleTapSendsOnce() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let id = try await stage(router)

        async let first = router.confirmByUserControl(proposalId: id)
        async let second = router.confirmByUserControl(proposalId: id)
        let outcomes = await [first, second]

        let count = await link.dispatchCount()
        XCTAssertEqual(count, 1, "two taps, one run")
        // Whichever landed second is told the truth: the same run, not a new
        // one and not a failure.
        XCTAssertTrue(outcomes.contains { $0 == .dispatched(runId: "run-1", task: "Goal:\nCount the files in Downloads") })
        XCTAssertTrue(outcomes.contains { $0 == .alreadyDispatched(runId: "run-1") })

        // A third, later tap is answered the same way.
        let third = await router.confirmByUserControl(proposalId: id)
        XCTAssertEqual(third, .alreadyDispatched(runId: "run-1"))
        let after = await link.dispatchCount()
        XCTAssertEqual(after, 1)
    }

    func testATapRacingTheModelsSubmitSendsOnce_tapFirst() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let id = try await stage(router)
        await router.modelTurnComplete()
        _ = await router.userTurnObserved("yes, send it")

        let tap = await router.confirmByUserControl(proposalId: id)
        guard case .dispatched(let runId, _) = tap else { return XCTFail("\(tap)") }

        // The model's own submit arrives a moment later for the same brief.
        let submitted = try requireResponse(await router.handle(
            LiveToolCall(id: "c9", name: "submit_hermes_task", args: ["proposal_id": id])))
        XCTAssertEqual(submitted["status"] as? String, "started",
                       "the model must not be told there is no proposal for work it just sent")
        XCTAssertEqual(submitted["run_id"] as? String, runId, "the SAME run, never a second one")
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 1)
    }

    func testATapRacingTheModelsSubmitSendsOnce_modelFirst() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let id = try await stage(router)
        await router.modelTurnComplete()
        _ = await router.userTurnObserved("yes, send it")

        let submitted = try requireResponse(await router.handle(
            LiveToolCall(id: "c9", name: "submit_hermes_task", args: ["proposal_id": id])))
        XCTAssertEqual(submitted["status"] as? String, "started")
        let runId = try XCTUnwrap(submitted["run_id"] as? String)

        // The user's thumb was already on its way down.
        let tap = await router.confirmByUserControl(proposalId: id)
        XCTAssertEqual(tap, .alreadyDispatched(runId: runId))
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: Declining and explaining

    func testDecliningDiscardsAndBlocksALaterModelSubmit() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let id = try await stage(router)
        await router.modelTurnComplete()

        let declined = await router.declineByUserControl(proposalId: id)
        XCTAssertTrue(declined)
        let staged = await router.pendingProposal()
        XCTAssertNil(staged, "nothing may still be staged after a decline")

        let submitted = try requireResponse(await router.handle(
            LiveToolCall(id: "c2", name: "submit_hermes_task", args: ["proposal_id": id])))
        XCTAssertEqual(submitted["status"] as? String, "blocked")
        XCTAssertEqual(submitted["error"] as? String,
                       "REJECTED: no active proposal. Stage and read back a complete brief first.")
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 0)
    }

    func testDecliningAStaleIdChangesNothing() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let id = try await stage(router)
        let declined = await router.declineByUserControl(proposalId: "some-other-id")
        XCTAssertFalse(declined)
        let still = await router.pendingProposal()
        XCTAssertEqual(still?.id, id, "the staged brief must survive a stale decline")
    }

    func testLetMeExplainKeepsTheProposalStagedAndStillConfirmable() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let id = try await stage(router)
        await router.modelTurnComplete()

        let matches = await router.isStagedByUserControl(proposalId: id)
        XCTAssertTrue(matches)
        let other = await router.isStagedByUserControl(proposalId: "other")
        XCTAssertFalse(other)

        // Nothing was sent and nothing changed.
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 0)
        let staged = await router.pendingProposal()
        XCTAssertEqual(staged?.id, id)

        // The user can still tap Yes afterwards.
        let tap = await router.confirmByUserControl(proposalId: id)
        guard case .dispatched = tap else { return XCTFail("\(tap)") }
        let after = await link.dispatchCount()
        XCTAssertEqual(after, 1)
    }

    // MARK: Failures

    func testADispatchFailureLeavesTheProposalStagedAndSaysNothingWasSent() async throws {
        let link = FakeLinkService()
        await link.setDispatchResult(.failure(.agentUnreachable("")))
        let router = makeRouter(link)
        let id = try await stage(router)

        let outcome = await router.confirmByUserControl(proposalId: id)
        XCTAssertEqual(
            outcome,
            .failed(message: "Hermes is not reachable from your Mac. Nothing was sent."))

        let staged = await router.pendingProposal()
        XCTAssertEqual(staged?.id, id, "the brief stays on screen so it can be tried again")

        // And it really can be tried again, once the Mac is back.
        await link.setDispatchResult(.success(LinkDispatchResult(
            status: "started", runId: "run-7", message: "ok", origin: "device:d1")))
        let retry = await router.confirmByUserControl(proposalId: id)
        XCTAssertEqual(retry, .dispatched(runId: "run-7", task: "Goal:\nCount the files in Downloads"))
    }

    func testEveryDispatchFailureIsNamedAndEndsWithNothingWasSent() {
        let cases: [LinkError] = [.notPaired, .unreachable("timed out"), .agentUnreachable(""),
                                  .tasksUnavailable, .dispatchFailed("boom")]
        for error in cases {
            let message = ToolRouter.userFacingDispatchFailure(error)
            XCTAssertTrue(message.hasSuffix("Nothing was sent."), message)
        }
    }

    // MARK: The model's own path is untouched

    func testTheModelStillCannotSubmitWithoutAUserTurn() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let id = try await stage(router)
        await router.modelTurnComplete()
        // No user turn, no tap.
        let submitted = try requireResponse(await router.handle(
            LiveToolCall(id: "c2", name: "submit_hermes_task", args: ["proposal_id": id])))
        XCTAssertEqual(submitted["status"] as? String, "blocked")
        XCTAssertEqual(submitted["error"] as? String,
                       "REJECTED: no distinct response from Nate was observed after the proposal read-back.")
        XCTAssertEqual(submitted["active_proposal_id"] as? String, id)
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 0, "the buttons existing must not relax this")
    }

    func testTheModelCannotReachTheUserControlPathByNamingIt() async throws {
        let link = FakeLinkService()
        let router = makeRouter(link)
        let id = try await stage(router)
        // Whatever the model calls it, there is no tool that maps to the tap.
        for name in ["claimByUserControl", "confirm_by_user_control", "answer_proposal_button",
                     "press_yes", "user_control_confirm"] {
            let response = try requireResponse(await router.handle(
                LiveToolCall(id: "x", name: name, args: ["proposal_id": id])))
            XCTAssertEqual(response["status"] as? String, "error")
            XCTAssertEqual(response["error"] as? String, "\(name) is not available on the phone.")
        }
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 0)
        let staged = await router.pendingProposal()
        XCTAssertEqual(staged?.id, id, "and nothing it said changed the staged brief")
    }

    // MARK: Through the coordinator — what Iris is told

    func testYesDispatchesTracksAndTellsIrisItIsAlreadySent() async throws {
        let link = FakeLinkService()
        let transport = FakeTransport()
        let coordinator = makeCoordinator(link, transport)
        await coordinator.handle(.setupComplete)
        let router = await coordinator.toolRouter
        let id = try await stage(router)

        let outcome = await coordinator.answerStagedProposal(.yes, proposalId: id)
        XCTAssertEqual(outcome, .sent(runId: "run-1"))

        let turns = await transport.turns()
        let event = try XCTUnwrap(turns.first { $0.hasPrefix("SYSTEM_EVENT_USER_CONFIRMED_BY_BUTTON") })
        XCTAssertTrue(event.contains("proposal_id: \(id)"))
        XCTAssertTrue(event.contains("run_id: run-1"))
        // The desktop's baked-in prompt has never seen this event name, so the
        // text has to carry its whole meaning.
        XCTAssertTrue(event.contains("ALREADY SENT"))
        XCTAssertTrue(event.contains("Do NOT call submit_hermes_task"))
        XCTAssertTrue(event.contains("Nate"))
        await coordinator.close()
    }

    func testTheConfirmationEventIsInjectedOnlyAfterTheDispatchResultIsKnown() async throws {
        let link = FakeLinkService()
        await link.setDispatchResult(.failure(.unreachable("timed out")))
        let transport = FakeTransport()
        let coordinator = makeCoordinator(link, transport)
        await coordinator.handle(.setupComplete)
        let router = await coordinator.toolRouter
        let id = try await stage(router)

        let outcome = await coordinator.answerStagedProposal(.yes, proposalId: id)
        guard case .failed(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.hasSuffix("Nothing was sent."))

        let turns = await transport.turns()
        XCTAssertFalse(
            turns.contains { $0.hasPrefix("SYSTEM_EVENT_USER_CONFIRMED_BY_BUTTON") },
            "Iris must never be told a task was sent when it was not")
        await coordinator.close()
    }

    func testNoDiscardsAndTellsIris() async throws {
        let link = FakeLinkService()
        let transport = FakeTransport()
        let coordinator = makeCoordinator(link, transport)
        await coordinator.handle(.setupComplete)
        let router = await coordinator.toolRouter
        let id = try await stage(router)

        let outcome = await coordinator.answerStagedProposal(.no, proposalId: id)
        XCTAssertEqual(outcome, .declined)
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 0)

        let turns = await transport.turns()
        let event = try XCTUnwrap(turns.first { $0.hasPrefix("SYSTEM_EVENT_USER_DECLINED_BY_BUTTON") })
        XCTAssertTrue(event.contains("proposal_id: \(id)"))
        XCTAssertTrue(event.contains("NOTHING was sent"))
        await coordinator.close()
    }

    func testLetMeExplainTellsIrisToStopAndListenAndKeepsTheBriefStaged() async throws {
        let link = FakeLinkService()
        let transport = FakeTransport()
        let coordinator = makeCoordinator(link, transport)
        await coordinator.handle(.setupComplete)
        let router = await coordinator.toolRouter
        let id = try await stage(router)

        let outcome = await coordinator.answerStagedProposal(.explain, proposalId: id)
        XCTAssertEqual(outcome, .explaining)

        let turns = await transport.turns()
        let event = try XCTUnwrap(turns.first { $0.hasPrefix("SYSTEM_EVENT_USER_WANTS_TO_EXPLAIN") })
        XCTAssertTrue(event.contains("still staged and still unsent"))
        XCTAssertTrue(event.contains("propose_hermes_task again"))

        let staged = await router.pendingProposal()
        XCTAssertEqual(staged?.id, id)
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 0)
        await coordinator.close()
    }

    func testAStaleTapTellsIrisNothingAtAll() async throws {
        let link = FakeLinkService()
        let transport = FakeTransport()
        let coordinator = makeCoordinator(link, transport)
        await coordinator.handle(.setupComplete)
        let router = await coordinator.toolRouter
        _ = try await stage(router)

        let outcome = await coordinator.answerStagedProposal(.yes, proposalId: "gone")
        XCTAssertEqual(outcome, .stale)
        let turns = await transport.turns()
        XCTAssertFalse(turns.contains { $0.contains("_BY_BUTTON") })
        let count = await link.dispatchCount()
        XCTAssertEqual(count, 0)
        await coordinator.close()
    }

    /// Seen on device: Gemini's ten-minute reset wiped the card and the buttons
    /// while the user was still reading the brief. A pending question must
    /// survive a reconnect on screen — and only the TAP may still confirm it.
    func testAReconnectKeepsTheQuestionOnScreenAndOnlyATapCanStillConfirmIt() async throws {
        let link = FakeLinkService()
        let first = FakeTransport()
        let coordinator = makeCoordinator(link, first)
        await coordinator.handle(.setupComplete)
        let router = await coordinator.toolRouter
        let id = try await stage(router)
        // Everything the VOICE path needs was in place before the drop.
        await router.modelTurnComplete()
        _ = await router.userTurnObserved("yes, send it")

        let second = FakeTransport()
        await coordinator.reattach(transport: second, resumed: true)
        await coordinator.handle(.setupComplete)

        // The brief is still there, unchanged.
        let staged = await router.pendingProposal()
        XCTAssertEqual(staged?.id, id, "the question must not vanish from the screen")

        // A spoken yes from before the drop no longer counts: the model has to
        // stage and re-read before its own submit is accepted.
        let submitted = await router.handle(LiveToolCall(
            id: "c9", name: "submit_hermes_task", args: ["proposal_id": id]
        ))
        XCTAssertEqual(submitted?["status"] as? String, "blocked")
        var count = await link.dispatchCount()
        XCTAssertEqual(count, 0, "a reconnect must never confirm anything by voice")

        // The tap still works, because the complete brief is on screen.
        let outcome = await coordinator.answerStagedProposal(.yes, proposalId: id)
        guard case .sent = outcome else { return XCTFail("expected the tap to send, got \(outcome)") }
        count = await link.dispatchCount()
        XCTAssertEqual(count, 1, "exactly one dispatch")
        let cleared = await router.pendingProposal()
        XCTAssertNil(cleared)
        await coordinator.close()
    }

    /// A completion must not be spoken over "Should I send that?".
    func testACompletionIsHeldWhileAQuestionIsWaitingAndSpokenAfterTheAnswer() async throws {
        let link = FakeLinkService()
        await link.setStatus(.success(LinkTaskStatus(runId: "run-0", status: "completed")), for: "run-0")
        await link.setResult(
            .success(LinkTaskResult(runId: "run-0", task: "earlier", status: "completed",
                                    output: "Earlier task finished.", instructions: "")),
            for: "run-0")
        let transport = FakeTransport()
        let coordinator = makeCoordinator(link, transport)
        await coordinator.handle(.setupComplete)
        let router = await coordinator.toolRouter

        let id = try await stage(router)          // a question is now on screen
        await coordinator.handle(.turnComplete)   // Iris has finished asking it
        await coordinator.track(runId: "run-0")   // …and an earlier run finishes

        try? await Task.sleep(nanoseconds: 2_600_000_000)   // more than one poll
        var spoken = await transport.turns().contains { $0.contains("run_id: run-0") }
        XCTAssertFalse(spoken, "the completion must wait while a question is pending")

        _ = await coordinator.answerStagedProposal(.no, proposalId: id)
        await coordinator.handle(.turnComplete)   // Iris acknowledges the decline
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && !spoken {
            spoken = await transport.turns().contains { $0.contains("run_id: run-0") }
            if !spoken { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(spoken, "held, not dropped: it is announced once the question is answered")
        await coordinator.close()
    }

    func testTheRunIsTrackedSoItsCompletionIsStillAnnounced() async throws {
        let link = FakeLinkService()
        await link.setStatus(.success(LinkTaskStatus(runId: "run-1", status: "completed")), for: "run-1")
        await link.setResult(
            .success(LinkTaskResult(runId: "run-1", task: "t", status: "completed",
                                    output: "Counted 42 files.", instructions: "")),
            for: "run-1")
        let transport = FakeTransport()
        let coordinator = makeCoordinator(link, transport)
        await coordinator.handle(.setupComplete)
        let router = await coordinator.toolRouter
        let id = try await stage(router)
        _ = await coordinator.answerStagedProposal(.yes, proposalId: id)
        await coordinator.handle(.turnComplete)

        let deadline = Date().addingTimeInterval(8)
        var announced = false
        while Date() < deadline && !announced {
            announced = await transport.turns().contains { $0.contains("run_id: run-1") }
            if !announced { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(announced, "a run started by a tap must still be announced when it finishes")
        await coordinator.close()
    }
}
