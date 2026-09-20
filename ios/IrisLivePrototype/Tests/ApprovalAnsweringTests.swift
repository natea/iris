//
//  ApprovalAnsweringTests.swift
//
//  The rules behind the big Approve / Deny buttons (LINK_API.md §4, §11.5):
//  exactly one request per tap, the decision strings the route accepts and no
//  others, never an answer to a request that changed under the user, an honest
//  word for `409 approval_not_pending`, and the model's own
//  `approve_hermes_action` path left exactly as strict as it was.
//

import XCTest
@testable import IrisLivePrototype

/// Counts calls and can be made to fail, so a test can prove that NOTHING was
/// sent rather than only that the UI said so.
actor CountingApprovalService: LinkTaskService {
    private(set) var calls: [(runId: String, decision: String)] = []
    var result: Result<Void, LinkError> = .success(())
    /// Held open so a second tap can arrive while the first is travelling.
    private var gate: CheckedContinuation<Void, Never>?
    private var holding = false

    func setResult(_ value: Result<Void, LinkError>) { result = value }
    func hold() { holding = true }
    func release() {
        holding = false
        gate?.resume()
        gate = nil
    }
    func callCount() -> Int { calls.count }
    func decisions() -> [String] { calls.map(\.decision) }

    func status() async throws -> LinkStatus {
        LinkStatus(deviceId: "d1", deviceName: "T", hermesReachable: true,
                   userName: "Nate", liveModel: "m", voice: "v", accent: "")
    }
    func dispatchTask(task: String, urgency: String) async throws -> LinkDispatchResult {
        LinkDispatchResult(status: "started", runId: "r", message: "", origin: "device:d1")
    }
    func listTasks(undelivered: Bool) async throws -> [LinkTask] { [] }
    func taskStatus(runId: String) async throws -> LinkTaskStatus { LinkTaskStatus(runId: runId, status: "running") }
    func taskStatus(runId: String, stepsSince: Int?) async throws -> LinkTaskDetail {
        LinkTaskDetail(task: LinkTaskStatus(runId: runId, status: "running"))
    }
    func taskResult(runId: String) async throws -> LinkTaskResult { throw LinkError.taskNotFinished }
    func stopTask(runId: String) async throws -> String { "stopping" }
    func resolveApproval(runId: String, decision: String) async throws {
        calls.append((runId, decision))
        if holding {
            await withCheckedContinuation { continuation in
                if holding { gate = continuation } else { continuation.resume() }
            }
        }
        try result.get()
    }
    func markAnnounced(runId: String) async throws {}
}

@MainActor
final class ApprovalAnsweringTests: XCTestCase {

    private let approval = PendingApproval(
        requestId: "approval:9f3c41",
        summary: "Hermes wants to run: rm -rf build",
        canApproveFromPhone: true
    )

    // MARK: Decision mapping

    func testTheBigButtonsMapToTheRoutesOwnValues() async {
        let service = CountingApprovalService()
        let answerer = ApprovalAnswerer()
        _ = await answerer.answer(.once, approval: approval, runId: "run-1",
                                  currentRequestId: approval.requestId, service: service)
        let approveOnly = await service.decisions()
        XCTAssertEqual(approveOnly, ["once"], "Approve means allow ONCE")

        let denyService = CountingApprovalService()
        let denier = ApprovalAnswerer()
        _ = await denier.answer(.deny, approval: approval, runId: "run-1",
                                currentRequestId: approval.requestId, service: denyService)
        let denied = await denyService.decisions()
        XCTAssertEqual(denied, ["deny"])
    }

    func testOnlyTheFourDocumentedDecisionsExist() {
        XCTAssertEqual(Set(ApprovalDecision.allCases.map(\.rawValue)),
                       ["once", "session", "always", "deny"])
        // The split the buttons are built on: these two authorize commands
        // that do not exist yet, so they keep a confirmation.
        XCTAssertTrue(ApprovalDecision.session.authorizesFutureCommands)
        XCTAssertTrue(ApprovalDecision.always.authorizesFutureCommands)
        XCTAssertFalse(ApprovalDecision.once.authorizesFutureCommands)
        XCTAssertFalse(ApprovalDecision.deny.authorizesFutureCommands)
    }

    // MARK: Exactly once

    func testASecondTapOnTheSameRequestSendsNothingMore() async {
        let service = CountingApprovalService()
        let answerer = ApprovalAnswerer()
        let first = await answerer.answer(.once, approval: approval, runId: "run-1",
                                          currentRequestId: approval.requestId, service: service)
        XCTAssertEqual(first, .answered(.once))
        let second = await answerer.answer(.once, approval: approval, runId: "run-1",
                                           currentRequestId: approval.requestId, service: service)
        XCTAssertEqual(second, .alreadyAnswered(.once))
        let count = await service.callCount()
        XCTAssertEqual(count, 1, "two taps, one request")
    }

    func testATapArrivingWhileTheFirstIsTravellingSendsNothingMore() async {
        let service = CountingApprovalService()
        await service.hold()
        let answerer = ApprovalAnswerer()

        let first = Task { @MainActor in
            await answerer.answer(.once, approval: approval, runId: "run-1",
                                  currentRequestId: approval.requestId, service: service)
        }
        // Let the first reach the service and block there.
        while await service.callCount() == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        let second = await answerer.answer(.deny, approval: approval, runId: "run-1",
                                           currentRequestId: approval.requestId, service: service)
        XCTAssertEqual(second, .alreadyAnswered(.deny), "the second tap sends nothing")
        await service.release()
        _ = await first.value
        let count = await service.callCount()
        XCTAssertEqual(count, 1, "and only one decision ever reached the Mac")
    }

    // MARK: Staleness

    func testARequestThatChangedUnderTheUserIsNotAnswered() async {
        let service = CountingApprovalService()
        let answerer = ApprovalAnswerer()
        // The run has moved on to a different question since the card was drawn.
        let outcome = await answerer.answer(
            .once, approval: approval, runId: "run-1",
            currentRequestId: "approval:something-else", service: service)
        XCTAssertEqual(outcome, .stale)
        let count = await service.callCount()
        XCTAssertEqual(count, 0, "nothing may be answered on the user's behalf")
        XCTAssertTrue(answerer.lastMessage.contains("Nothing was sent"))
    }

    func testARunWaitingOnNothingIsNotAnswered() async {
        let service = CountingApprovalService()
        let answerer = ApprovalAnswerer()
        let outcome = await answerer.answer(.deny, approval: approval, runId: "run-1",
                                            currentRequestId: nil, service: service)
        XCTAssertEqual(outcome, .stale)
        let count = await service.callCount()
        XCTAssertEqual(count, 0)
    }

    // MARK: Failures

    func testAlreadyAnsweredIsReportedPlainly() async {
        let service = CountingApprovalService()
        await service.setResult(.failure(.approvalNotPending))
        let answerer = ApprovalAnswerer()
        let outcome = await answerer.answer(.once, approval: approval, runId: "run-1",
                                            currentRequestId: approval.requestId, service: service)
        XCTAssertEqual(outcome, .notPending)
        XCTAssertEqual(answerer.lastMessage, "That request was already answered.")

        // And it is not retried into a second request.
        let again = await answerer.answer(.once, approval: approval, runId: "run-1",
                                          currentRequestId: approval.requestId, service: service)
        XCTAssertEqual(again, .alreadyAnswered(.once))
        let count = await service.callCount()
        XCTAssertEqual(count, 1)
    }

    func testAnUnreachableMacSaysNothingWasSent() async {
        let service = CountingApprovalService()
        await service.setResult(.failure(.unreachable("timed out")))
        let answerer = ApprovalAnswerer()
        let outcome = await answerer.answer(.once, approval: approval, runId: "run-1",
                                            currentRequestId: approval.requestId, service: service)
        XCTAssertEqual(outcome, .failed("Your Mac is not reachable right now. Nothing was sent."))
        // A failed send is NOT remembered: the request is still open.
        await service.setResult(.success(()))
        let retry = await answerer.answer(.once, approval: approval, runId: "run-1",
                                          currentRequestId: approval.requestId, service: service)
        XCTAssertEqual(retry, .answered(.once))
    }

    func testAnUnpairedPhoneSendsNothing() async {
        let answerer = ApprovalAnswerer()
        let outcome = await answerer.answer(.once, approval: approval, runId: "run-1",
                                            currentRequestId: approval.requestId, service: nil)
        guard case .failed(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.hasSuffix("Nothing was sent."))
    }

    // MARK: Telling the session

    func testTheSessionIsToldOnlyAfterTheDecisionReallyLanded() async {
        let service = CountingApprovalService()
        var told: [(String, String, ApprovalDecision, String)] = []
        let answerer = ApprovalAnswerer()
        answerer.onAnswered = { told.append(($0, $1, $2, $3)) }

        await service.setResult(.failure(.agentUnreachable("")))
        _ = await answerer.answer(.once, approval: approval, runId: "run-1",
                                  currentRequestId: approval.requestId, service: service)
        XCTAssertTrue(told.isEmpty, "Iris must not be told about something that did not happen")

        await service.setResult(.success(()))
        _ = await answerer.answer(.once, approval: approval, runId: "run-1",
                                  currentRequestId: approval.requestId, service: service)
        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(told[0].0, "run-1")
        XCTAssertEqual(told[0].1, approval.requestId)
        XCTAssertEqual(told[0].2, .once)
    }

    func testTheApprovalEventExplainsItselfWithoutTheDesktopsPrompt() {
        let event = SystemEvent.userAnsweredApprovalByButton(
            runId: "run-1", requestId: "approval:9f3c41", decision: "once",
            summary: "Hermes wants to run: rm -rf build", userName: "Nate")
        XCTAssertTrue(event.hasPrefix("SYSTEM_EVENT_USER_APPROVED_BY_BUTTON"))
        XCTAssertTrue(event.contains("run_id: run-1"))
        XCTAssertTrue(event.contains("decision: once"))
        XCTAssertTrue(event.contains("ALREADY SENT"))
        XCTAssertTrue(event.contains("Do NOT call approve_hermes_action"))
        // The summary is Hermes' text, and the event says so rather than
        // letting it read as an instruction.
        XCTAssertTrue(event.contains("display-only text from Hermes"))

        let denial = SystemEvent.userAnsweredApprovalByButton(
            runId: "run-1", requestId: "r", decision: "deny", summary: "x", userName: "Nate")
        XCTAssertTrue(denial.hasPrefix("SYSTEM_EVENT_USER_DENIED_BY_BUTTON"))
    }

    // MARK: The model's own approval path is unchanged

    func testTheModelStillCannotApproveWithoutTheUserAnsweringInTheirOwnTurn() async throws {
        let link = FakeLinkService()
        let router = ToolRouter(link: link, userName: "Nate", sessionId: "s",
                                settleInterval: 0, settleTimeout: 0)
        // No question asked, no turn ended, no answer heard.
        let blocked = try requireResponse(await router.handle(LiveToolCall(
            id: "a1", name: "approve_hermes_action",
            args: ["run_id": "run-1", "choice": "once"])))
        XCTAssertEqual(blocked["status"] as? String, "blocked")
        let calls = await link.approvalCalls()
        XCTAssertTrue(calls.isEmpty, "the big buttons must not relax the spoken gate")

        // With a real user turn it still works exactly as before.
        await router.modelTurnComplete()
        _ = await router.userTurnObserved("yes, allow it once")
        let resolved = try requireResponse(await router.handle(LiveToolCall(
            id: "a2", name: "approve_hermes_action",
            args: ["run_id": "run-1", "choice": "once"])))
        XCTAssertEqual(resolved["status"] as? String, "resolved")
        let after = await link.approvalCalls()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].decision, "once")
    }
}
