//
//  SessionReconnectTests.swift
//
//  What must survive a reconnect, and what must NOT. The coordinator is
//  driven with a fake transport and a scripted Link service, so every
//  assertion is about the contract rather than about a socket.
//

import XCTest
@testable import IrisLivePrototype

// MARK: - Fakes

/// Records what was sent, per connection. One instance per socket.
actor FakeTransport: LiveTransport {
    private(set) var textTurns: [String] = []
    private(set) var toolResponses: [[LiveFunctionResponse]] = []

    func sendToolResponses(_ responses: [LiveFunctionResponse]) async {
        toolResponses.append(responses)
    }

    func sendTextTurn(_ text: String, turnComplete: Bool) async {
        textTurns.append(text)
    }

    func turns() -> [String] { textTurns }
    func toolResponseCount() -> Int { toolResponses.count }
}

/// A Link service whose `taskStatus` blocks until the test lets it go, so a
/// tool call can be held in flight across a reconnect on purpose.
actor HeldLinkService: LinkTaskService {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var statusCalls = 0

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }

    private func hold() async {
        if released { return }
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { waiter = continuation }
        }
    }

    func status() async throws -> LinkStatus {
        LinkStatus(deviceId: "d1", deviceName: "Test", hermesReachable: true,
                   userName: "Nate", liveModel: "models/test", voice: "Zephyr", accent: "")
    }
    func dispatchTask(task: String, urgency: String) async throws -> LinkDispatchResult {
        LinkDispatchResult(status: "started", runId: "run-1", message: "ok", origin: "device:d1")
    }
    func listTasks(undelivered: Bool) async throws -> [LinkTask] { [] }
    func taskStatus(runId: String) async throws -> LinkTaskStatus {
        statusCalls += 1
        await hold()
        return LinkTaskStatus(runId: runId, status: "running")
    }
    func taskResult(runId: String) async throws -> LinkTaskResult { throw LinkError.taskNotFinished }
    func stopTask(runId: String) async throws -> String { "stopping" }
    func resolveApproval(runId: String, decision: String) async throws {}
    func markAnnounced(runId: String) async throws {}
}

// MARK: - Tests

final class SessionReconnectTests: XCTestCase {

    private func poll(
        timeout: TimeInterval = 3,
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return false
    }

    // MARK: Telling the user

    func testAResumedConnectionDoesNotGreetAgain() async {
        let link = FakeLinkService()
        let first = FakeTransport()
        let coordinator = SessionCoordinator(link: link, transport: first, userName: "Nate")

        await coordinator.handle(.setupComplete)
        let greeting = await first.turns()
        XCTAssertEqual(greeting.count, 1)
        XCTAssertTrue(greeting[0].hasPrefix("SYSTEM_EVENT_SESSION_START"))

        let second = FakeTransport()
        await coordinator.reattach(transport: second, resumed: true)
        await coordinator.handle(.setupComplete)

        // The conversation never stopped, so Iris says nothing about it.
        let afterResume = await second.turns()
        XCTAssertTrue(afterResume.isEmpty, "a resumed session must not re-greet: \(afterResume)")
        await coordinator.close()
    }

    func testAConversationThatCouldNotBeRestoredIsAnnouncedOutLoud() async {
        let link = FakeLinkService()
        let first = FakeTransport()
        let coordinator = SessionCoordinator(link: link, transport: first, userName: "Nate")
        await coordinator.handle(.setupComplete)

        let second = FakeTransport()
        await coordinator.reattach(transport: second, resumed: false)
        await coordinator.handle(.setupComplete)

        let said = await second.turns()
        XCTAssertEqual(said.count, 1, "exactly one notice, not a second greeting")
        // The contract's own mechanism (§7.1), so the baked-in prompt knows
        // what to do with it, and it must actually say the thread was lost.
        XCTAssertTrue(said[0].hasPrefix("SYSTEM_EVENT_SESSION_START"))
        XCTAssertTrue(said[0].contains("could NOT be restored"))
        XCTAssertTrue(said[0].contains("Nate"))
        await coordinator.close()
    }

    // MARK: The dispatch gate

    func testAReconnectNeverTurnsAnUnconfirmedProposalIntoAConfirmedOne() async {
        let link = FakeLinkService()
        let first = FakeTransport()
        let coordinator = SessionCoordinator(
            link: link, transport: first, userName: "Nate",
            settleInterval: 0.01, settleTimeout: 0.03
        )
        await coordinator.handle(.setupComplete)
        let router = await coordinator.toolRouter

        // Stage a brief, read it back, and let the user answer — everything
        // the gate needs to allow a submit.
        let proposed = await router.handle(LiveToolCall(
            id: "c1", name: "propose_hermes_task",
            args: ["goal": "Count the files in Downloads"]
        ))
        let proposalId = proposed?["proposal_id"] as? String ?? ""
        XCTAssertFalse(proposalId.isEmpty)
        await router.modelTurnComplete()
        _ = await router.userTurnObserved("yes, send it")

        // The socket dies here — after the confirmation, before the submit.
        let second = FakeTransport()
        await coordinator.reattach(transport: second, resumed: true)
        await coordinator.handle(.setupComplete)

        let submitted = await router.handle(LiveToolCall(
            id: "c2", name: "submit_hermes_task", args: ["proposal_id": proposalId]
        ))
        XCTAssertEqual(submitted?["status"] as? String, "blocked")
        let dispatched = await link.dispatchCount()
        XCTAssertEqual(dispatched, 0, "nothing may reach Hermes")
        // And the model is told to stage it again rather than to claim it sent.
        let instructions = submitted?["instructions"] as? String ?? ""
        XCTAssertFalse(instructions.isEmpty)
        await coordinator.close()
    }

    func testAFreshConversationAlsoRotatesTheSessionId() async {
        let link = FakeLinkService()
        let first = FakeTransport()
        let coordinator = SessionCoordinator(
            link: link, transport: first, userName: "Nate",
            settleInterval: 0.01, settleTimeout: 0.03
        )
        await coordinator.handle(.setupComplete)
        let router = await coordinator.toolRouter
        let proposed = await router.handle(LiveToolCall(
            id: "c1", name: "propose_hermes_task", args: ["goal": "Do the thing"]
        ))
        let proposalId = proposed?["proposal_id"] as? String ?? ""
        await router.modelTurnComplete()
        _ = await router.userTurnObserved("go ahead")

        let second = FakeTransport()
        await coordinator.reattach(transport: second, resumed: false)
        await coordinator.handle(.setupComplete)

        let submitted = await router.handle(LiveToolCall(
            id: "c2", name: "submit_hermes_task", args: ["proposal_id": proposalId]
        ))
        XCTAssertEqual(submitted?["status"] as? String, "blocked")
        let dispatched = await link.dispatchCount()
        XCTAssertEqual(dispatched, 0)
        await coordinator.close()
    }

    // MARK: Tool calls

    func testAToolResultFromTheDeadSocketIsDiscardedNotAnswered() async {
        let link = HeldLinkService()
        let first = FakeTransport()
        let coordinator = SessionCoordinator(link: link, transport: first, userName: "Nate")
        await coordinator.handle(.setupComplete)

        // A tool call that is still running when the socket dies.
        await coordinator.handle(.toolCall([
            LiveToolCall(id: "tc1", name: "get_hermes_task_status", args: ["run_id": "run-1"])
        ]))
        let started = await poll { await link.statusCalls > 0 }
        XCTAssertTrue(started, "the tool call never started")

        let second = FakeTransport()
        await coordinator.reattach(transport: second, resumed: true)
        await coordinator.handle(.setupComplete)

        // Only now does the Mac answer. That call id means nothing to the new
        // connection and the model there is not waiting for it.
        await link.release()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let answeredOnDeadSocket = await first.toolResponseCount()
        let answeredOnNewSocket = await second.toolResponseCount()
        XCTAssertEqual(answeredOnDeadSocket, 0)
        XCTAssertEqual(answeredOnNewSocket, 0)
        await coordinator.close()
    }

    // MARK: Announcements

    func testAnAnnouncementInterruptedByTheResetIsRetriedAndNotAcknowledged() async {
        let link = FakeLinkService()
        await link.setUndelivered([
            LinkTask(runId: "run-9", task: "count files", status: "completed",
                     origin: "device:d1", createdAt: 1, updatedAt: 2)
        ])
        await link.setResult(
            .success(LinkTaskResult(runId: "run-9", task: "count files", status: "completed",
                                    output: "42 files.", instructions: "")),
            for: "run-9"
        )
        let first = FakeTransport()
        let coordinator = SessionCoordinator(link: link, transport: first, userName: "Nate")

        await coordinator.handle(.setupComplete)
        // The greeting turn ends, which is what lets the announcement go out.
        await coordinator.handle(.turnComplete)
        let firstTurns = await first.turns()
        XCTAssertTrue(
            firstTurns.contains { $0.hasPrefix("SYSTEM_EVENT_HERMES_COMPLETE") },
            "the completion should have been injected: \(firstTurns)"
        )
        // LINK_API.md §8 step 3: not acknowledged until the turn completes.
        let ackedBeforeReset = await link.announcedRuns()
        XCTAssertTrue(ackedBeforeReset.isEmpty)

        // The reset lands mid-announcement.
        let second = FakeTransport()
        await coordinator.reattach(transport: second, resumed: true)
        await coordinator.handle(.setupComplete)

        let secondTurns = await second.turns()
        let retried = secondTurns.filter { $0.hasPrefix("SYSTEM_EVENT_HERMES_COMPLETE") }
        XCTAssertEqual(retried.count, 1, "exactly once, not zero and not twice: \(secondTurns)")
        XCTAssertTrue(retried[0].contains("run_id: run-9"))
        XCTAssertTrue(retried[0].contains("42 files."))
        let ackedAfterRetry = await link.announcedRuns()
        XCTAssertTrue(ackedAfterRetry.isEmpty, "still unacknowledged")

        // Now it really is delivered.
        await coordinator.handle(.turnComplete)
        let ackedAtLast = await link.announcedRuns()
        XCTAssertEqual(ackedAtLast, ["run-9"])
        await coordinator.close()
    }

    func testRunTrackingSurvivesAReconnect() async {
        let link = FakeLinkService()
        let first = FakeTransport()
        let coordinator = SessionCoordinator(link: link, transport: first, userName: "Nate")
        await coordinator.handle(.setupComplete)
        await coordinator.track(runId: "run-7", note: "dispatched before the drop")

        await link.setStatus(
            .success(LinkTaskStatus(runId: "run-7", status: "completed")), for: "run-7"
        )
        await link.setResult(
            .success(LinkTaskResult(runId: "run-7", task: "t", status: "completed",
                                    output: "done", instructions: "")),
            for: "run-7"
        )

        let second = FakeTransport()
        await coordinator.reattach(transport: second, resumed: true)
        await coordinator.handle(.setupComplete)
        await coordinator.handle(.turnComplete)

        // The poll that notices run-7 finished belongs to the conversation,
        // not to the socket that dispatched it.
        let announced = await poll(timeout: 8) {
            await second.turns().contains { $0.contains("run_id: run-7") }
        }
        XCTAssertTrue(announced, "a run dispatched before the drop must still be announced")
        await coordinator.close()
    }
}
