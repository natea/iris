//
//  NewChatRecovery.swift
//  IrisLivePrototype
//
//  The one-tap recovery for the commonest real failure: Hermes allows one
//  client per chat, the Hermes Desktop app had Iris's pinned chat open, and
//  every dispatch failed until somebody started a new one.
//
//  SECURITY INVARIANT, and the reason this is a separate object rather than a
//  method on the tool router: THE MODEL MUST NOT BE ABLE TO REACH IT. There is
//  no tool named for it in `ToolRouter.declaredTools`, no system event that
//  invokes it, and no path from a transcript, a push payload or a tool call to
//  `start(...)`. Its only callers are the failure card's button closures — a
//  deliberate tap on a trusted surface, behind an explicit confirmation.
//
//  Why the confirmation: this repins the Hermes chat for the MAC as well.
//  There is one pinned chat, not one per surface. The user is told that in the
//  dialog, in those words, before anything happens.
//
//  Exactly-once: a double tap performs one call. The in-flight `Task` is the
//  ledger, so a second tap arriving while the Mac is still answering awaits
//  that same answer rather than starting a second chat.
//

import Foundation

@MainActor
public final class NewChatRecoveryController: ObservableObject {

    public enum Outcome: Equatable {
        /// A new chat exists and the failed brief is running again in it.
        case retried(sessionId: String, runId: String)
        /// A new chat exists; the retry did not start, and we say so rather
        /// than implying the work resumed.
        case startedOnly(sessionId: String, note: String)
        /// Nothing changed. The message is the Mac's own words.
        case failed(message: String)

        public var message: String {
            switch self {
            case .retried:
                return "Started a new Hermes chat and sent that task again."
            case .startedOnly(_, let note):
                return note.isEmpty
                    ? "Started a new Hermes chat, but the task did not start again. Ask Iris to send it."
                    : "Started a new Hermes chat, but the task did not start again: \(note)"
            case .failed(let message):
                return message
            }
        }

        public var isSuccess: Bool {
            if case .failed = self { return false }
            return true
        }
    }

    @Published public private(set) var isWorking = false
    /// The last outcome, in plain words. Never a claim that something landed.
    @Published public private(set) var outcome: Outcome?
    /// The run the recovery produced, so the UI can open it.
    @Published public private(set) var newRunId: String?

    private let service: LinkTaskService?
    private var inFlight: Task<Outcome, Never>?

    public init(service: LinkTaskService?) {
        self.service = service
    }

    /// What the confirmation dialog says, verbatim. It names the consequence
    /// the user cannot see from the phone: the Mac follows too.
    public static let confirmationMessage =
        "Iris will use a new Hermes chat from now on, on your Mac too. Your old chat stays in Hermes."

    /// Starts a new Hermes chat, re-dispatching `retryRunId`'s exact brief
    /// when the Mac allows it. Exactly once per controller-in-flight window.
    @discardableResult
    public func start(retryRunId: String?) async -> Outcome {
        // A second tap joins the first call instead of making a second chat.
        if let inFlight { return await inFlight.value }
        guard let service else {
            let result = Outcome.failed(message: LinkError.notPaired.message)
            outcome = result
            return result
        }
        isWorking = true
        let work = Task<Outcome, Never> {
            do {
                let chat = try await service.startNewChat(retryRunId: retryRunId)
                if let runId = chat.runId, !runId.isEmpty {
                    return .retried(sessionId: chat.sessionId, runId: runId)
                }
                return .startedOnly(sessionId: chat.sessionId, note: chat.retryMessage)
            } catch let error as LinkError {
                return .failed(message: error.message)
            } catch {
                return .failed(message: "Could not start a new Hermes chat.")
            }
        }
        inFlight = work
        let result = await work.value
        inFlight = nil
        isWorking = false
        outcome = result
        if case .retried(_, let runId) = result { newRunId = runId }
        if result.isSuccess { Haptics.success() } else { Haptics.error() }
        return result
    }

    /// Clears the last outcome so the card stops reporting a finished action.
    public func acknowledge() {
        outcome = nil
        newRunId = nil
    }
}
