//
//  FailureDecodingTests.swift
//
//  LINK_API.md §15 and §16 on the phone: decoding a classified failure,
//  mapping the wire codes to typed errors, the one-tap recovery's guards, and
//  the rule that history is never news.
//

import XCTest
@testable import IrisLivePrototype

final class FailureDecodingTests: XCTestCase {

    // The real refusal, as Hermes wrote it on 2026-09-16.
    private static let sessionInUseJSON: [String: Any] = [
        "code": "session_in_use",
        "message": "That chat is open in Hermes Desktop. Close it there, or I can start a new chat.",
        "recovery": "start_new_chat",
        "detail": "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.",
    ]

    // MARK: Decoding

    func testEveryCodeAndRecoveryDecodes() {
        for code in HermesFailureCode.allCases where code != .unknown {
            let failure = LinkFailure(json: [
                "code": code.rawValue, "message": "because", "recovery": "retry",
            ])
            XCTAssertEqual(failure?.code, code, code.rawValue)
        }
        for hint in HermesRecovery.allCases {
            let failure = LinkFailure(json: [
                "code": "unknown", "message": "because", "recovery": hint.rawValue,
            ])
            XCTAssertEqual(failure?.recovery, hint, hint.rawValue)
        }
    }

    func testTheSessionInUseBlockDecodesWithItsAgreedSentence() {
        let failure = LinkFailure(json: Self.sessionInUseJSON)
        XCTAssertEqual(failure?.code, .sessionInUse)
        XCTAssertEqual(
            failure?.message,
            "That chat is open in Hermes Desktop. Close it there, or I can start a new chat."
        )
        XCTAssertEqual(failure?.recovery, .startNewChat)
        XCTAssertEqual(failure?.actionTitle, "Start a new chat and try again")
        XCTAssertTrue(failure?.detail.hasPrefix("This chat is open in another Hermes") == true)
        XCTAssertFalse(failure?.code.meansHermesUnreachable == true)
    }

    /// A newer Mac must never be able to make a reason disappear from an older
    /// phone: an unknown code keeps the sentence AND the raw code.
    func testAnUnknownCodeKeepsTheMessageTheCodeAndTheDetail() {
        let failure = LinkFailure(json: [
            "code": "quantum_flux",
            "message": "Hermes tripped over something new.",
            "recovery": "sideways",
            "detail": "QuantumFluxError: unstable",
        ])
        XCTAssertEqual(failure?.code, .unknown)
        XCTAssertEqual(failure?.rawCode, "quantum_flux")
        XCTAssertEqual(failure?.message, "Hermes tripped over something new.")
        // An unrecognised recovery is not invented into an action.
        XCTAssertEqual(failure?.recovery, HermesRecovery.none)
        XCTAssertNil(failure?.actionTitle)
        XCTAssertEqual(failure?.detail, "QuantumFluxError: unstable")
    }

    func testAMissingCodeStillCarriesTheOriginalText() {
        let failure = LinkFailure(json: ["detail": "Widget frobnicator exploded"])
        XCTAssertEqual(failure?.code, .unknown)
        XCTAssertEqual(failure?.detail, "Widget frobnicator exploded")
        XCTAssertEqual(
            failure?.message,
            "Hermes couldn't run that, and this app doesn't recognise the reason."
        )
    }

    func testAnEmptyOrAbsentBlockIsDroppedRatherThanShownBlank() {
        XCTAssertNil(LinkFailure(json: nil))
        XCTAssertNil(LinkFailure(json: [:]))
        XCTAssertNil(LinkFailure(json: ["code": "session_in_use"]))
        XCTAssertNil(LinkFailure(json: "not an object"))
    }

    func testOnlyGatewayUnreachableMayClaimHermesIsUnreachable() {
        for code in HermesFailureCode.allCases {
            XCTAssertEqual(
                code.meansHermesUnreachable,
                code == .gatewayUnreachable,
                "\(code.rawValue) must not claim Hermes is unreachable"
            )
        }
    }

    // MARK: The task models

    func testATaskDecodesItsFailureRestoredAndSessionFields() {
        let task = LinkTask(json: [
            "run_id": "run-1",
            "task": "Summarise the commits",
            "status": "failed",
            "origin": "device:abc",
            "session_id": "20260916_174926_797a3b",
            "restored": false,
            "read_only": false,
            "failure": Self.sessionInUseJSON,
        ])
        XCTAssertEqual(task?.failure?.code, .sessionInUse)
        XCTAssertEqual(task?.sessionId, "20260916_174926_797a3b")
        XCTAssertFalse(task?.isHistory == true)
    }

    func testARunThatDidNotFailCarriesNoFailure() {
        let task = LinkTask(json: [
            "run_id": "run-2", "status": "completed", "origin": "desktop", "failure": NSNull(),
        ])
        XCTAssertNil(task?.failure)
    }

    func testARestoredRunDecodesAsReadOnlyHistory() {
        let task = LinkTask(json: [
            "run_id": "history:20260916_174926_797a3b:msg_412",
            "task": "Draft the release notes",
            "status": "completed",
            "origin": "history",
            "session_id": "20260916_174926_797a3b",
            "restored": true,
            "read_only": true,
            "updated_at": 1_789_947_620_033,
        ])
        XCTAssertEqual(task?.restored, true)
        XCTAssertEqual(task?.readOnly, true)
        XCTAssertEqual(task?.isHistory, true)
        XCTAssertEqual(task?.originLabel, "from the chat history")
        // Milliseconds, like every other Link timestamp.
        XCTAssertEqual(task?.updatedAt, 1_789_947_620_033)
    }

    /// An older Mac sends neither field; nothing is inferred from their absence.
    func testMissingHistoryFieldsDefaultToALiveRun() {
        let task = LinkTask(json: ["run_id": "run-3", "status": "completed", "origin": "desktop"])
        XCTAssertFalse(task?.restored == true)
        XCTAssertFalse(task?.readOnly == true)
        XCTAssertFalse(task?.isHistory == true)
        XCTAssertEqual(task?.originLabel, "from the Mac")
    }

    // MARK: LinkError mapping

    func testEachClassifiedErrorCarriesTheMacsOwnSentence() {
        let cases: [(LinkError, HermesFailureCode, HermesRecovery)] = [
            (.sessionInUse("open in Hermes Desktop"), .sessionInUse, .startNewChat),
            (.backendStartFailed("would not start"), .backendStartFailed, .checkMac),
            (.modelUnreachable("model is down"), .modelUnreachable, .retry),
            (.authFailed("key mismatch"), .authFailed, .checkMac),
            (.runLimit("out of steps"), .runLimit, .retry),
            (.agentUnreachable("not answering"), .gatewayUnreachable, .checkMac),
        ]
        for (error, code, recovery) in cases {
            XCTAssertEqual(error.failure?.code, code, error.message)
            XCTAssertEqual(error.failure?.recovery, recovery, error.message)
            // The desktop's words, not ours.
            XCTAssertEqual(error.failure?.message, error.message)
        }
    }

    func testOnlyTheReallyUnreachableErrorSaysHermesIsNotReachable() {
        XCTAssertEqual(
            ToolRouter.userFacingDispatchFailure(LinkError.agentUnreachable("")),
            "Hermes is not reachable from your Mac. Nothing was sent."
        )
        // The failure that used to produce that same sentence, and never
        // should have.
        let locked = LinkError.sessionInUse(
            "That chat is open in Hermes Desktop. Close it there, or I can start a new chat."
        )
        let text = ToolRouter.userFacingDispatchFailure(locked)
        XCTAssertEqual(
            text,
            "That chat is open in Hermes Desktop. Close it there, or I can start a new chat. Nothing was sent."
        )
        XCTAssertFalse(text.contains("not reachable"))
    }

    func testTheProposalCardOffersRecoveryOnlyForALockedChat() {
        XCTAssertEqual(ToolRouter.dispatchRecovery(LinkError.sessionInUse(""))?.recovery, .startNewChat)
        XCTAssertNil(ToolRouter.dispatchRecovery(LinkError.modelUnreachable("")))
        XCTAssertNil(ToolRouter.dispatchRecovery(LinkError.agentUnreachable("")))
        XCTAssertNil(ToolRouter.dispatchRecovery(LinkError.notPaired))
    }

    func testTheModelIsToldTheRealCauseRatherThanTheCatchAll() {
        XCTAssertEqual(
            ToolRouter.dispatchErrorCode(LinkError.sessionInUse("chat is open")),
            "session_in_use: chat is open"
        )
        XCTAssertEqual(
            ToolRouter.dispatchErrorCode(LinkError.hermesFailure(code: "quantum_flux", message: "odd")),
            "quantum_flux: odd"
        )
    }

    // MARK: The system event (LINK_API.md §15.4)

    func testAFailedRunsEventCarriesTheReasonAndForbidsAResult() {
        let text = SystemEvent.hermesComplete(
            runId: "run-7", status: "failed", output: "", userName: "Nate",
            failure: LinkFailure(json: Self.sessionInUseJSON)
        )
        XCTAssertTrue(text.hasPrefix("SYSTEM_EVENT_HERMES_COMPLETE\n"))
        XCTAssertTrue(text.contains("failure_code: session_in_use"))
        XCTAssertTrue(text.contains("recovery: start_new_chat"))
        XCTAssertTrue(text.contains("The task did NOT run."))
        XCTAssertTrue(text.contains("That chat is open in Hermes Desktop."))
        // No result to claim, and no tool to reach for.
        XCTAssertFalse(text.contains("authoritative_hermes_result"))
        XCTAssertTrue(text.contains("Start a new chat and try again"))
        XCTAssertTrue(text.contains("You CANNOT start a new chat yourself"))
        // The only mention of "unreachable" is the instruction FORBIDDING it;
        // the reason itself never says Hermes could not be reached.
        XCTAssertFalse(
            text.components(separatedBy: "failure_reason:").last?.contains("unreachable") == true
        )
        XCTAssertTrue(text.contains("do not say Hermes is unreachable unless the reason says so"))
    }

    func testACompletedRunsEventIsUntouched() {
        let text = SystemEvent.hermesComplete(
            runId: "run-8", status: "completed", output: "42 files", userName: "Nate"
        )
        XCTAssertTrue(text.contains("authoritative_hermes_result:\n42 files"))
        XCTAssertFalse(text.contains("failure_code"))
    }

    func testACheckMacFailureDoesNotOfferAButtonInTheSpokenText() {
        let text = SystemEvent.hermesComplete(
            runId: "run-9", status: "failed", output: "", userName: "Nate",
            failure: LinkFailure(
                code: .backendStartFailed,
                message: "Hermes' backend would not start (MCP server 'strava' failed to authenticate).",
                recovery: .checkMac
            )
        )
        XCTAssertTrue(text.contains("needs attention on the Mac"))
        XCTAssertFalse(text.contains("Start a new chat and try again"))
    }

    // MARK: History is never news (LINK_API.md §16.3)

    func testRestoredAndEarlierRunsNeverEarnANotification() {
        let live = LinkTask(
            runId: "run-live", task: "Real work", status: "completed", origin: "device:abc"
        )
        let restored = LinkTask(
            runId: "history:s1:m1", task: "Old work", status: "completed", origin: "history",
            restored: true, readOnly: true, sessionId: "s1"
        )
        let earlier = LinkTask(
            runId: "run-old", task: "Older work", status: "completed", origin: "device:abc",
            readOnly: true, sessionId: "s1"
        )
        let candidates = RunNotifier.candidates(from: [live, restored, earlier], notified: [])
        XCTAssertEqual(candidates.map(\.runId), ["run-live"])
    }

    func testAFailedRunsNotificationBodyIsTheReasonNotTheTaskTitle() {
        let run = LinkTask(
            runId: "run-1", task: "Summarise the commits", status: "failed", origin: "device:abc",
            failure: LinkFailure(json: Self.sessionInUseJSON)
        )
        XCTAssertEqual(
            RunNotifier.body(for: run),
            "That chat is open in Hermes Desktop. Close it there, or I can start a new chat."
        )
        let ok = LinkTask(runId: "run-2", task: "Tidy up", status: "completed", origin: "device:abc")
        XCTAssertEqual(RunNotifier.body(for: ok), "Tidy up")
    }
}

// MARK: - The one-tap recovery

@MainActor
final class NewChatRecoveryTests: XCTestCase {

    /// Through the EXISTENTIAL, deliberately. `startNewChat` is a protocol
    /// REQUIREMENT; if it were extension-only this test would silently
    /// exercise the refusing default and prove nothing — which is exactly the
    /// bug that once stopped the phone ever asking for steps.
    private func controller(_ fake: FakeLinkService) -> NewChatRecoveryController {
        let service: any LinkTaskService = fake
        return NewChatRecoveryController(service: service)
    }

    func testAConfirmedTapStartsAChatAndRetriesTheExactRun() async {
        let fake = FakeLinkService()
        let outcome = await controller(fake).start(retryRunId: "run-failed")
        XCTAssertEqual(outcome, .retried(sessionId: "api_new_1", runId: "run-retried"))
        let calls = await fake.newChatRetryIds()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first ?? nil, "run-failed")
    }

    func testADoubleTapMakesExactlyOneChat() async {
        let fake = FakeLinkService()
        await fake.setNewChatDelay(80_000_000)
        let controller = controller(fake)
        async let first = controller.start(retryRunId: "run-failed")
        // Give the first call time to register as in flight.
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let second = controller.start(retryRunId: "run-failed")
        let results = await [first, second]
        XCTAssertEqual(results[0], results[1], "both taps see the same answer")
        let count = await fake.newChatCallCount()
        XCTAssertEqual(count, 1, "a double tap must not start two chats")
    }

    func testTheMacsRefusalIsReportedInItsOwnWords() async {
        let fake = FakeLinkService()
        await fake.setNewChatResult(.failure(.retryNotAllowed("That run didn't fail, so there is nothing to retry.")))
        let outcome = await controller(fake).start(retryRunId: "run-ok")
        XCTAssertEqual(
            outcome,
            .failed(message: "That run didn't fail, so there is nothing to retry.")
        )
        XCTAssertFalse(outcome.isSuccess)
    }

    func testARestoredRunIsRefusedAsHistory() async {
        let fake = FakeLinkService()
        await fake.setNewChatResult(.failure(.notALiveRun("That one is history.")))
        let outcome = await controller(fake).start(retryRunId: "history:s1:m1")
        XCTAssertEqual(outcome, .failed(message: "That one is history."))
    }

    /// The chat really was made; the work did not restart. Saying "sent it
    /// again" here would be the lie this whole change exists to remove.
    func testAChatWithNoRetryIsReportedHonestly() async {
        let fake = FakeLinkService()
        await fake.setNewChatResult(.success(
            LinkNewChat(sessionId: "api_new_2", runId: nil,
                        retryError: "gateway_unreachable",
                        retryMessage: "Hermes isn't answering on your Mac.")
        ))
        let outcome = await controller(fake).start(retryRunId: "run-failed")
        XCTAssertEqual(
            outcome,
            .startedOnly(sessionId: "api_new_2", note: "Hermes isn't answering on your Mac.")
        )
        XCTAssertTrue(outcome.message.contains("did not start again"))
        XCTAssertFalse(outcome.message.contains("sent that task again"))
    }

    func testWithNoServiceNothingIsClaimed() async {
        let outcome = await NewChatRecoveryController(service: nil).start(retryRunId: "run-1")
        XCTAssertFalse(outcome.isSuccess)
    }

    func testTheConfirmationNamesTheConsequenceForTheMac() {
        XCTAssertEqual(
            NewChatRecoveryController.confirmationMessage,
            "Iris will use a new Hermes chat from now on, on your Mac too. Your old chat stays in Hermes."
        )
    }

    /// §16.4 through the existential, same reason as above.
    func testEarlierChatsAreFetchedThroughTheProtocolRequirement() async throws {
        let fake = FakeLinkService()
        let earlier = LinkTask(
            runId: "run-old", task: "Older work", status: "completed", origin: "desktop",
            readOnly: true, sessionId: "20260916_174926_797a3b"
        )
        await fake.setAllTasks(LinkTaskList(tasks: [], earlier: [earlier]))
        let service: any LinkTaskService = fake
        let list = try await service.listAllTasks()
        XCTAssertEqual(list.earlier.map(\.runId), ["run-old"])
        XCTAssertEqual(list.earlier.first?.sessionId, "20260916_174926_797a3b")
    }

    /// No tool exists for the recovery, and none may ever be added: the model
    /// must not be able to repin the user's Hermes chat.
    func testTheModelHasNoToolForStartingANewChat() {
        for name in ToolRouter.declaredTools {
            XCTAssertFalse(name.contains("session"), "\(name) must not exist")
            XCTAssertFalse(name.contains("new_chat"), "\(name) must not exist")
        }
    }
}

// MARK: - The banner and the proposal card

@MainActor
final class FailurePresentationTests: XCTestCase {

    /// §15: the banner must not rewrite the Mac's explanation back into the
    /// generic sentence this whole change exists to remove.
    func testTheBannerPassesTheMacsSentenceThroughUntouched() {
        let sentence = "That chat is open in Hermes Desktop. Close it there, or I can start a new chat."
        XCTAssertEqual(ErrorPresentation.humanize(sentence), sentence)
        XCTAssertEqual(ErrorPresentation.humanize(LinkError.sessionInUse(sentence).message), sentence)
        // Socket noise is still humanized; that mapping is untouched.
        XCTAssertEqual(
            ErrorPresentation.humanize("Socket receive ended: Socket is not connected"),
            "The connection to Gemini dropped. Tap the orb to start again."
        )
    }

    /// A dispatch that failed because the chat was locked offers the recovery
    /// on the card; nothing else does.
    func testTheProposalOutcomeCarriesTheRecoveryOnlyForALockedChat() {
        let locked = ToolRouter.UserControlOutcome.failed(
            message: "…",
            recovery: ToolRouter.dispatchRecovery(LinkError.sessionInUse("open in Hermes Desktop"))
        )
        guard case .failed(_, let recovery) = locked else { return XCTFail("wrong case") }
        XCTAssertEqual(recovery?.recovery, .startNewChat)

        let unreachable = ToolRouter.UserControlOutcome.failed(
            message: "…",
            recovery: ToolRouter.dispatchRecovery(LinkError.agentUnreachable(""))
        )
        guard case .failed(_, let none) = unreachable else { return XCTFail("wrong case") }
        XCTAssertNil(none)
    }
}
