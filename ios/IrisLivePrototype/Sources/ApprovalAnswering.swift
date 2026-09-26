//
//  ApprovalAnswering.swift
//  IrisLivePrototype
//
//  One implementation of "the user tapped an answer to a Hermes approval",
//  shared by the run screen and the main screen.
//
//  It exists because the rules around a §11.5 approval are the rules that are
//  easy to get subtly wrong twice: exactly one request per tap, never an
//  answer to a request that has changed underneath the user, an honest word
//  for `409 approval_not_pending`, and never a claim that a decision landed
//  when it did not.
//
//  SECURITY INVARIANT. `answer(...)` is called from SwiftUI button closures
//  only — the big Approve / Deny buttons and the confirmed broader grants.
//  Nothing the model emits reaches it. The model's own route to an approval is
//  `approve_hermes_action`, which goes through `ToolRouter` and `ApprovalGate`
//  and is untouched by this file. A push payload can only put a run on screen;
//  it can never answer one.
//

import Foundation

/// Told after a decision really reached the Mac: run id, request id, the
/// decision as sent, and the summary the user was looking at.
typealias ApprovalAnsweredHandler = (String, String, ApprovalDecision, String) -> Void

@MainActor
final class ApprovalAnswerer: ObservableObject {

    /// What a tap did. Every case is a fact about what reached the Mac.
    enum Outcome: Equatable {
        /// The Mac accepted this decision for this request.
        case answered(ApprovalDecision)
        /// The run is waiting on a DIFFERENT request now (or on none), so the
        /// tap belonged to something the user is no longer looking at.
        /// Nothing was sent.
        case stale
        /// This exact request was already answered from this phone. Nothing
        /// was sent a second time.
        case alreadyAnswered(ApprovalDecision)
        /// The Mac says there is nothing pending: answered on the Mac, or it
        /// timed out.
        case notPending
        /// Nothing was sent; plain-language reason.
        case failed(String)

        /// What the screen shows afterwards.
        var message: String {
            switch self {
            case .answered(let decision), .alreadyAnswered(let decision):
                return decision.isDenial
                    ? "Denied. Hermes has been told no."
                    : "Approved (\(decision.rawValue)). Hermes is carrying on."
            case .stale:
                return "Hermes has moved on to a different question. Nothing was sent — this is what it is waiting on now."
            case .notPending:
                return "That request was already answered."
            case .failed(let message):
                return message
            }
        }
    }

    /// The request id currently being sent, so the buttons can disable
    /// themselves and show progress on the one that was pressed.
    @Published private(set) var inFlightRequestId: String?
    /// The plain-language outcome of the last answer, or "".
    @Published var lastMessage = ""

    /// Request ids this phone has already answered. A second tap on the same
    /// request is answered from here instead of being sent again — the point
    /// of a big button is that it will get double-tapped.
    private var answered: [String: ApprovalDecision] = [:]

    /// Raised after a decision really reached the Mac, so a live session can
    /// be told. Set by the screen that owns the session; nil when there is no
    /// session to tell.
    var onAnswered: ApprovalAnsweredHandler?

    func isSending(_ requestId: String) -> Bool { inFlightRequestId == requestId }
    var isBusy: Bool { inFlightRequestId != nil }

    /// Sends one decision for one request.
    ///
    /// - Parameters:
    ///   - approval: the request whose COMPLETE text was on screen when the
    ///     button was tapped. This is what the decision is about.
    ///   - currentRequestId: what the run is waiting on according to the most
    ///     recent poll. A mismatch means the question changed under the user.
    @discardableResult
    func answer(
        _ decision: ApprovalDecision,
        approval: PendingApproval,
        runId: String,
        currentRequestId: String?,
        service: LinkTaskService?
    ) async -> Outcome {
        if let already = answered[approval.requestId] {
            lastMessage = Outcome.alreadyAnswered(already).message
            return .alreadyAnswered(already)
        }
        // The run moved on. Answering anyway would apply this decision to a
        // command the user has not read.
        guard let currentRequestId, currentRequestId == approval.requestId else {
            lastMessage = Outcome.stale.message
            return .stale
        }
        guard inFlightRequestId == nil else {
            // A second tap while the first is still travelling.
            return .alreadyAnswered(decision)
        }
        guard let service else {
            let outcome = Outcome.failed("This phone is not paired with your Mac. Nothing was sent.")
            lastMessage = outcome.message
            return outcome
        }

        inFlightRequestId = approval.requestId
        defer { inFlightRequestId = nil }
        do {
            try await service.resolveApproval(runId: runId, decision: decision.rawValue)
            answered[approval.requestId] = decision
            lastMessage = Outcome.answered(decision).message
            onAnswered?(runId, approval.requestId, decision, approval.summary)
            return .answered(decision)
        } catch LinkError.approvalNotPending {
            // Not a failure of this phone's: the Mac answered it, or Hermes
            // gave up waiting. Remembered so a retry does not resend either.
            answered[approval.requestId] = decision
            lastMessage = Outcome.notPending.message
            return .notPending
        } catch {
            let outcome = Outcome.failed(Self.plainFailure(error))
            lastMessage = outcome.message
            return outcome
        }
    }

    /// Every one of these ends by saying nothing was sent.
    static func plainFailure(_ error: Error) -> String {
        switch error as? LinkError {
        case .notPaired:
            return "This phone is not paired with your Mac any more. Nothing was sent."
        case .unreachable:
            return "Your Mac is not reachable right now. Nothing was sent."
        case .agentUnreachable:
            return "Hermes is not reachable from your Mac. Nothing was sent."
        case .taskUnknown:
            return "Your Mac does not know that run any more. Nothing was sent."
        default:
            return "That answer could not be sent to Hermes. Nothing was sent."
        }
    }
}

// MARK: - Which grants need a second look

extension ApprovalDecision {

    /// `once` and `deny` answer the command ON SCREEN, so a single deliberate
    /// tap on a surface showing that command in full is the whole gate — the
    /// same condition the proposal buttons meet.
    ///
    /// `session` and `always` authorize commands that DO NOT EXIST YET and
    /// that the user therefore cannot have read. Those keep a confirmation
    /// step, and they stay behind a smaller secondary control.
    var authorizesFutureCommands: Bool {
        self == .session || self == .always
    }

    /// What the confirmation says it will mean.
    var consequence: String {
        switch self {
        case .once: return "Runs this one command."
        case .session: return "Allows commands like this for the rest of this Hermes session, without asking again."
        case .always: return "Allows commands like this from now on, without asking again."
        case .deny: return "Tells Hermes no."
        }
    }
}
