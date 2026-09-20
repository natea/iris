//
//  DispatchGate.swift
//  IrisLivePrototype
//
//  The phone's port of electron/hermesGate.mjs (LINK_API.md §6).
//
//  A submit is bound to one immutable proposal, one session, and an actual
//  user turn that happened AFTER the read-back finished. The model decides
//  what the user meant; this type only enforces ordering and identity, never a
//  confirmation vocabulary.
//
//  Pure value type: no I/O, no clock of its own (every call that can expire a
//  proposal takes `now`), no global state. One instance per Live session.
//

import Foundation

// MARK: - Dispatch gate

public struct DispatchGate: Sendable, Equatable {

    /// LINK_API.md §6.1. A proposal older than this behaves exactly like no
    /// proposal at all.
    public static let proposalTTL: TimeInterval = 5 * 60

    public enum Stage: String, Sendable, Equatable {
        case awaitingReadback = "awaiting_readback"
        case awaitingUser = "awaiting_user"
        case readbackInterrupted = "readback_interrupted"
    }

    /// The rejection reasons of `hermesGate.mjs`, name for name. The raw
    /// values are the strings the contract's tables key on.
    public enum Reason: String, Sendable, Equatable, Error {
        case emptyTask = "empty_task"
        case noProposal = "no_proposal"
        case proposalMismatch = "proposal_mismatch"
        case sessionMismatch = "session_mismatch"
        case readbackInterrupted = "readback_interrupted"
        case noUserTurn = "no_user_turn"
        case notAwaitingUser = "not_awaiting_user"
        case readbackInProgress = "readback_in_progress"
        case emptyResponse = "empty_response"
    }

    public struct Proposal: Sendable, Equatable, Identifiable {
        public let id: String
        public let task: String
        public let urgency: String
        public let sessionId: String
        public internal(set) var stage: Stage
        public let proposedAt: Date
        public internal(set) var userResponse: String
        public internal(set) var userTurnObserved: Bool
    }

    public static let validUrgencies: Set<String> = ["low", "normal", "high"]

    private var proposal: Proposal?

    public init() {}

    // MARK: Expiry

    /// Mirrors `expire()`: every *read* drops a stale proposal first. The JS
    /// deliberately does not expire inside the turn-observation calls, so
    /// neither does this.
    private mutating func expire(_ now: Date) {
        guard let current = proposal else { return }
        if now.timeIntervalSince(current.proposedAt) > Self.proposalTTL { proposal = nil }
    }

    // MARK: Transitions

    /// Replaces any existing proposal. An empty brief is refused and leaves the
    /// staged proposal untouched.
    @discardableResult
    public mutating func propose(
        task: String,
        urgency: String = "normal",
        sessionId: String = "",
        id: String = UUID().uuidString,
        now: Date = Date()
    ) -> Result<Proposal, Reason> {
        let cleanTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTask.isEmpty else { return .failure(.emptyTask) }
        let cleanUrgency = Self.validUrgencies.contains(urgency) ? urgency : "normal"
        let staged = Proposal(
            id: id,
            task: cleanTask,
            urgency: cleanUrgency,
            sessionId: sessionId.trimmingCharacters(in: .whitespacesAndNewlines),
            stage: .awaitingReadback,
            proposedAt: now,
            userResponse: "",
            userTurnObserved: false
        )
        proposal = staged
        return .success(staged)
    }

    /// The model finished the read-back turn with no barge-in.
    public mutating func markModelTurnComplete() {
        guard proposal?.stage == .awaitingReadback else { return }
        proposal?.stage = .awaitingUser
    }

    /// A barge-in does not prove the complete brief was heard, so the proposal
    /// can never be claimed again — it has to be restaged.
    public mutating func markModelTurnInterrupted() {
        guard proposal?.stage == .awaitingReadback else { return }
        proposal?.stage = .readbackInterrupted
    }

    /// Records that a real user turn followed the read-back. The transcript is
    /// kept for observability only; the model owns the semantic decision.
    @discardableResult
    public mutating func recordUserResponse(
        _ text: String,
        allowDuringReadback: Bool = false
    ) -> Result<Stage, Reason> {
        guard let current = proposal,
              current.stage == .awaitingReadback || current.stage == .awaitingUser
        else { return .failure(.notAwaitingUser) }
        if current.stage == .awaitingReadback && !allowDuringReadback {
            return .failure(.readbackInProgress)
        }
        let response = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !response.isEmpty else { return .failure(.emptyResponse) }
        proposal?.userResponse = response
        proposal?.userTurnObserved = true
        return .success(current.stage)
    }

    /// A fresh Live session (not a resume) clears anything staged.
    public mutating func reset() { proposal = nil }

    // MARK: Reads

    public mutating func pendingProposal(now: Date = Date()) -> Proposal? {
        expire(now)
        return proposal
    }

    /// True while a staged proposal is still waiting for a terminal decision.
    public mutating func hasPendingProposal(now: Date = Date()) -> Bool {
        expire(now)
        guard let stage = proposal?.stage else { return false }
        return stage == .awaitingReadback || stage == .awaitingUser
    }

    /// The `active_proposal_id` every blocked tool result has to carry.
    public mutating func activeProposalId(now: Date = Date()) -> String? {
        expire(now)
        return proposal?.id
    }

    /// LINK_API.md §6.5: the model can call `submit_hermes_task` a few
    /// milliseconds before the user's final transcript lands. True while that
    /// race is still winnable, so the caller knows to wait rather than reject.
    public mutating func isSettling(now: Date = Date()) -> Bool {
        expire(now)
        guard let current = proposal else { return false }
        guard current.stage == .awaitingReadback || current.stage == .awaitingUser else { return false }
        return !current.userTurnObserved
    }

    // MARK: Terminal decisions

    @discardableResult
    public mutating func discard(
        proposalId: String,
        sessionId: String = "",
        now: Date = Date()
    ) -> Result<Proposal, Reason> {
        expire(now)
        guard let current = proposal else { return .failure(.noProposal) }
        guard !proposalId.isEmpty, proposalId == current.id else { return .failure(.proposalMismatch) }
        if !current.sessionId.isEmpty && sessionId != current.sessionId {
            return .failure(.sessionMismatch)
        }
        proposal = nil
        return .success(current)
    }

    /// Consumes the exact staged proposal. Succeeds only when all four of
    /// §6.3 hold, and clears the proposal on success.
    @discardableResult
    public mutating func claim(
        proposalId: String,
        sessionId: String = "",
        now: Date = Date()
    ) -> Result<Proposal, Reason> {
        expire(now)
        guard let current = proposal else { return .failure(.noProposal) }
        guard !proposalId.isEmpty, proposalId == current.id else { return .failure(.proposalMismatch) }
        if !current.sessionId.isEmpty && sessionId != current.sessionId {
            return .failure(.sessionMismatch)
        }
        if current.stage == .readbackInterrupted { return .failure(.readbackInterrupted) }
        guard current.stage == .awaitingUser, current.userTurnObserved else {
            return .failure(.noUserTurn)
        }
        proposal = nil
        return .success(current)
    }

    // MARK: Confirmation by an explicit on-screen control

    // ========================================================================
    // SECURITY INVARIANT — READ BEFORE CHANGING ANYTHING BELOW
    //
    // `claimByUserControl` and `restoreAfterUserControlDispatchFailed` exist
    // for ONE caller: the SwiftUI button closures on the pending-proposal card
    // (MainView → LiveSessionController.answerPendingProposal →
    // SessionCoordinator.answerStagedProposal → ToolRouter.confirmByUserControl).
    //
    // NOTHING the model emits may ever reach them. The model's only entry into
    // this file is `ToolRouter.execute`, which switches on the eight declared
    // tool names and maps `submit_hermes_task` to `claim` — never to this. A
    // transcript line, a system event, a push payload and a deep link are all
    // inert here for the same reason: none of them is a tool call, and none of
    // them has a path to the SwiftUI action closure either.
    //
    // WHY THIS IS NOT A HOLE IN THE TWO-STEP RULE (spec: "Confirmation by an
    // explicit control"). The voice path needs `stage == awaiting_user` and a
    // distinct user turn because that ordering is the only evidence the phone
    // has that the complete brief was HEARD. A tap carries its own, better
    // evidence: the complete brief is on screen, on a trusted surface, at the
    // moment of the tap. So read-back progress is deliberately NOT required —
    // tapping Yes while Iris is still reading it out is valid — but identity
    // still is: the id must be the one currently staged, and the session must
    // match. A tap for a brief that is no longer staged dispatches nothing.
    // ========================================================================

    /// Consumes the staged proposal on the authority of a deliberate tap on
    /// the trusted surface that is showing the complete brief.
    ///
    /// Only callable from the UI action closures. See the invariant above.
    @discardableResult
    public mutating func claimByUserControl(
        proposalId: String,
        sessionId: String = "",
        now: Date = Date()
    ) -> Result<Proposal, Reason> {
        expire(now)
        guard let current = proposal else { return .failure(.noProposal) }
        guard !proposalId.isEmpty, proposalId == current.id else { return .failure(.proposalMismatch) }
        if !current.sessionId.isEmpty && sessionId != current.sessionId {
            return .failure(.sessionMismatch)
        }
        // No stage or turn check: the tap IS the confirmation, and the brief it
        // confirms is the one on screen. Every other identity rule still holds.
        proposal = nil
        return .success(current)
    }

    /// Puts back a proposal that a tap claimed but that could not be
    /// dispatched, so the card stays up and the user can try again.
    ///
    /// Restores the exact value that was claimed — same id, same stage, same
    /// `userTurnObserved` — so a failed send neither strengthens nor weakens
    /// the model's own claim rules. Refused when anything newer has been
    /// staged in the meantime: the newest brief is the only one on screen.
    ///
    /// Only callable from the UI action path. See the invariant above.
    @discardableResult
    public mutating func restoreAfterUserControlDispatchFailed(
        _ claimed: Proposal,
        now: Date = Date()
    ) -> Bool {
        expire(now)
        guard proposal == nil else { return false }
        guard now.timeIntervalSince(claimed.proposedAt) <= Self.proposalTTL else { return false }
        proposal = claimed
        return true
    }

    // MARK: Contract wording (LINK_API.md §6.4)

    /// The `error` string `submit_hermes_task` must return for a rejection.
    public static func errorText(for reason: Reason, userName: String) -> String {
        switch reason {
        case .noProposal:
            return "REJECTED: no active proposal. Stage and read back a complete brief first."
        case .proposalMismatch:
            return "REJECTED: proposal_id does not match the exact brief shown to the user."
        case .sessionMismatch:
            return "REJECTED: the selected Hermes chat changed. Stage and confirm the brief again."
        case .readbackInterrupted:
            return "REJECTED: the proposal read-back was interrupted. Stage it again and let the full read-back finish before asking for confirmation."
        case .noUserTurn:
            return "REJECTED: no distinct response from \(userName) was observed after the proposal read-back."
        case .emptyTask, .notAwaitingUser, .readbackInProgress, .emptyResponse:
            return "REJECTED: no active proposal. Stage and read back a complete brief first."
        }
    }

    /// The `instructions` string that goes with it. `proposal_mismatch` says
    /// something different depending on whether a proposal is still staged.
    public static func instructions(for reason: Reason, activeProposalId: String?) -> String {
        switch reason {
        case .proposalMismatch:
            if activeProposalId != nil {
                return "Do not restage or repeat the readback. Retry submit_hermes_task using active_proposal_id if this is the proposal the user just confirmed."
            }
            return "Do not claim the task was sent."
        case .readbackInterrupted:
            return "Call propose_hermes_task with the corrected brief."
        case .noUserTurn:
            return "Keep the same proposal staged, end your turn, and wait for the user's response. If their response was not captured, ask one brief natural clarification. Never demand specific confirmation wording."
        default:
            return "Do not claim the task was sent."
        }
    }
}

// MARK: - Approval gate

/// The human gate `POST /link/tasks/:id/approval` requires (LINK_API.md §5.7):
/// Iris must describe the command, ask, END ITS TURN, and only resolve the
/// approval after the user has answered in a turn of their own.
///
/// Same shape as the dispatch gate and the same rule about barge-in: a
/// question the user talked over was not necessarily heard, so it does not
/// open the window.
public struct ApprovalGate: Sendable, Equatable {

    private var awaitingAnswer = false
    private var userAnswered = false
    private(set) public var lastAnswer = ""

    public init() {}

    /// The model ended a turn: if it asked the approval question, the user's
    /// next turn is the answer.
    public mutating func markModelTurnComplete() {
        awaitingAnswer = true
        userAnswered = false
    }

    /// A barge-in closes the window rather than opening it.
    public mutating func markModelTurnInterrupted() {
        awaitingAnswer = false
        userAnswered = false
    }

    public mutating func recordUserResponse(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard awaitingAnswer, !clean.isEmpty else { return }
        userAnswered = true
        lastAnswer = clean
    }

    public var userAnsweredInOwnTurn: Bool { userAnswered }

    /// Consumes the answer, so one spoken reply can authorize exactly one
    /// approval.
    public mutating func claim() -> Bool {
        guard userAnswered else { return false }
        userAnswered = false
        awaitingAnswer = false
        return true
    }

    public mutating func reset() {
        awaitingAnswer = false
        userAnswered = false
        lastAnswer = ""
    }
}
