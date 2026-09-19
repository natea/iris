//
//  ToolRouter.swift
//  IrisLivePrototype
//
//  Executes the eight function declarations the desktop bakes into the
//  ephemeral token (LINK_API.md §5) and returns EXACTLY the documented
//  `response` objects.
//
//  Two rules shape every line here:
//
//    1. The `instructions` strings are load-bearing. The model's next move is
//       decided by them, so they are returned verbatim, never paraphrased.
//    2. No invented run state. Every Link failure becomes an honest
//       `status: "error"` / `ok: false` result naming what happened. A tool
//       never reports a task as sent, running, or finished unless the Mac
//       said so.
//
//  The router owns the session's DispatchGate and ApprovalGate. It is an
//  actor, so the Live event stream and a tool call cannot interleave halfway
//  through a claim.
//

import Foundation

// MARK: - Brief formatting

/// Byte-for-byte port of the desktop's `formatHermesBrief` (main.mjs).
/// Sections joined by a blank line, omitted when empty, list items prefixed
/// with `- `. The brief has to stand alone: Hermes cannot hear the
/// conversation that produced it.
public enum HermesBrief {
    public static func format(
        goal: String,
        context: String = "",
        constraints: [String] = [],
        acceptanceCriteria: [String] = [],
        outputFormat: String = ""
    ) -> String {
        let cleanGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanGoal.isEmpty else { return "" }
        var sections = ["Goal:\n\(cleanGoal)"]
        let cleanContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanContext.isEmpty { sections.append("User-provided context:\n\(cleanContext)") }
        let list = { (values: [String]) in
            values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let cleanConstraints = list(constraints)
        if !cleanConstraints.isEmpty {
            sections.append("Constraints:\n" + cleanConstraints.map { "- \($0)" }.joined(separator: "\n"))
        }
        let cleanAcceptance = list(acceptanceCriteria)
        if !cleanAcceptance.isEmpty {
            sections.append("Acceptance criteria:\n" + cleanAcceptance.map { "- \($0)" }.joined(separator: "\n"))
        }
        let cleanFormat = outputFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanFormat.isEmpty { sections.append("Expected output:\n\(cleanFormat)") }
        return sections.joined(separator: "\n\n")
    }
}

// MARK: - System event templates (LINK_API.md §7)

public enum SystemEvent {

    public static func sessionStart(userName: String) -> String {
        "SYSTEM_EVENT_SESSION_START: Greet \(userName) once in one short sentence, then ask what they have in mind. Do not report service status unless asked."
    }

    /// `\n`-joined, exactly as `formatHermesCompletionEvent` in
    /// electron/hermesEvents.mjs builds it.
    public static func hermesComplete(
        runId: String,
        status: String,
        output: String,
        userName: String,
        wakingFromSleep: Bool = false
    ) -> String {
        var lines = [
            "SYSTEM_EVENT_HERMES_COMPLETE",
            "run_id: \(runId)",
            "status: \(status)",
            "instructions_to_iris:",
            "- Tell \(userName) Hermes has returned and summarize the authoritative result below in 1-3 sentences.",
            "- Preserve explicit counts, names, and quantities exactly; if unsure, omit them rather than infer.",
            "- Ask whether to review the details. Do not claim you performed Hermes's work.",
        ]
        if wakingFromSleep {
            lines.append("- Iris was woken for this result. Deliver it directly without a greeting.")
        }
        lines.append("authoritative_hermes_result:")
        let text = output.isEmpty ? "(Hermes returned no text output.)" : output
        lines.append(text)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Router

public actor ToolRouter {

    /// The names the token declares. Anything else is answered with an honest
    /// "this tool is not available on the phone" rather than a fake result.
    public static let declaredTools: Set<String> = [
        "check_hermes_status",
        "propose_hermes_task",
        "submit_hermes_task",
        "discard_hermes_proposal",
        "get_hermes_task_status",
        "stop_hermes_task",
        "approve_hermes_action",
        "read_hermes_task_result",
    ]

    public static let approvalChoices: Set<String> = ["once", "session", "always", "deny"]

    private let link: LinkTaskService
    private var userName: String
    private var sessionId: String

    private var gate = DispatchGate()
    private var approvalGate = ApprovalGate()

    /// LINK_API.md §6.5 — the settle window. Injectable so unit tests do not
    /// spend 1.6 s per rejected claim.
    private let settleInterval: TimeInterval
    private let settleTimeout: TimeInterval

    /// Ids the model cancelled (`toolCallCancellation`). A cancelled call's
    /// result is dropped rather than sent, and a cancelled `submit` is never
    /// dispatched.
    private var cancelledCalls: Set<String> = []

    /// Raised for every run this phone dispatched, so the run tracker can
    /// start polling it. Never used to report state to the model.
    public var onDispatch: (@Sendable (LinkDispatchResult, String) -> Void)?

    public init(
        link: LinkTaskService,
        userName: String,
        sessionId: String,
        settleInterval: TimeInterval = 0.04,
        settleTimeout: TimeInterval = 1.6
    ) {
        self.link = link
        self.userName = userName.isEmpty ? "the user" : userName
        self.sessionId = sessionId
        self.settleInterval = settleInterval
        self.settleTimeout = settleTimeout
    }

    public func setOnDispatch(_ handler: (@Sendable (LinkDispatchResult, String) -> Void)?) {
        onDispatch = handler
    }

    public func setUserName(_ name: String) {
        userName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "the user" : name
    }

    // MARK: Turn events the gates need

    public func modelTurnComplete() {
        gate.markModelTurnComplete()
        approvalGate.markModelTurnComplete()
    }

    public func modelTurnInterrupted() {
        gate.markModelTurnInterrupted()
        approvalGate.markModelTurnInterrupted()
    }

    /// A non-empty final input transcript. `allowDuringReadback` mirrors the
    /// desktop: a reply that lands while a *substantial* read-back has already
    /// been spoken still counts, because natural "yes" answers arrive just
    /// before `turnComplete`.
    @discardableResult
    public func userTurnObserved(_ text: String, allowDuringReadback: Bool = false) -> Bool {
        approvalGate.recordUserResponse(text)
        if case .success = gate.recordUserResponse(text, allowDuringReadback: allowDuringReadback) {
            return true
        }
        return false
    }

    /// A fresh Live session (not a resume) clears everything staged.
    public func resetSession(sessionId: String) {
        self.sessionId = sessionId
        gate.reset()
        approvalGate.reset()
        cancelledCalls.removeAll()
    }

    // MARK: Observability for the UI

    public func pendingProposal() -> DispatchGate.Proposal? { gate.pendingProposal() }

    // MARK: Cancellation

    public func cancel(ids: [String]) {
        for id in ids { cancelledCalls.insert(id) }
    }

    public func isCancelled(_ id: String) -> Bool { cancelledCalls.contains(id) }

    // MARK: Dispatch

    /// Executes one tool call and returns the `response` object to put in the
    /// function response. Returns nil when the call was cancelled while it was
    /// in flight — that result must not be sent.
    public func handle(_ call: LiveToolCall) async -> [String: Any]? {
        if !call.id.isEmpty && cancelledCalls.contains(call.id) { return nil }
        let response = await execute(call)
        if !call.id.isEmpty && cancelledCalls.contains(call.id) {
            cancelledCalls.remove(call.id)
            return nil
        }
        return response
    }

    private func execute(_ call: LiveToolCall) async -> [String: Any] {
        switch call.name {
        case "check_hermes_status": return await checkStatus()
        case "propose_hermes_task": return propose(call)
        case "submit_hermes_task": return await submit(call)
        case "discard_hermes_proposal": return discard(call)
        case "get_hermes_task_status": return await taskStatus(call)
        case "stop_hermes_task": return await stop(call)
        case "approve_hermes_action": return await approve(call)
        case "read_hermes_task_result": return await readResult(call)
        default:
            return [
                "status": "error",
                "error": "\(call.name) is not available on the phone.",
                "instructions": "Say that this needs the Mac. Do not pretend the action happened.",
            ]
        }
    }

    // MARK: 5.1 check_hermes_status

    private func checkStatus() async -> [String: Any] {
        do {
            let status = try await link.status()
            if status.hermesReachable {
                return ["reachable": true, "health": ["transport": "iris_link"]]
            }
            return [
                "reachable": false,
                "error": "Hermes is not reachable from the Mac.",
            ]
        } catch {
            // The two outages are different facts and the phone must say which
            // one it observed (LINK_API.md §3).
            return [
                "reachable": false,
                "error": Self.unreachableReason(error),
            ]
        }
    }

    /// Names which of the two things is down, never "something went wrong".
    static func unreachableReason(_ error: Error) -> String {
        switch error as? LinkError {
        case .notPaired:
            return "This phone is no longer paired with the Mac."
        case .unreachable(let detail):
            return "The Mac running Iris is not reachable (\(detail))."
        case .agentUnreachable:
            return "Hermes is not reachable from the Mac."
        case .tasksUnavailable:
            return "This version of Iris on the Mac cannot take tasks from the phone."
        case .some(let link):
            return link.message
        case .none:
            return "The Mac running Iris is not reachable."
        }
    }

    // MARK: 5.2 propose_hermes_task

    private func propose(_ call: LiveToolCall) -> [String: Any] {
        let brief = HermesBrief.format(
            goal: call.string("goal"),
            context: call.string("context"),
            constraints: call.stringArray("constraints"),
            acceptanceCriteria: call.stringArray("acceptance_criteria"),
            outputFormat: call.string("output_format")
        )
        let urgency = call.string("urgency")
        switch gate.propose(task: brief, urgency: urgency, sessionId: sessionId) {
        case .failure:
            return ["status": "error", "error": "A complete task brief is required."]
        case .success(let staged):
            return [
                "status": "proposed",
                "proposal_id": staged.id,
                "task": staged.task,
                "instructions": [
                    "Now read this exact brief back to \(userName) in one or two short sentences, ask \"Should I send this to Hermes?\", and END YOUR TURN.",
                    "Do NOT call submit_hermes_task yet — it will be rejected until they answer.",
                    "Interpret \(userName)'s next response by meaning, not by matching specific words. If they clearly authorize sending, submit proposal_id \"\(staged.id)\". If they decline, call discard_hermes_proposal with that proposal_id. If they change any detail, call propose_hermes_task again and read back the replacement proposal. If their intent is ambiguous, ask one short natural clarification.",
                ].joined(separator: " "),
            ]
        }
    }

    // MARK: 5.3 submit_hermes_task

    private func submit(_ call: LiveToolCall) async -> [String: Any] {
        let proposalId = call.string("proposal_id")

        // The settle window: the model often calls submit a few milliseconds
        // before the user's final transcript lands. Waiting turns a benign
        // race into a success instead of a spurious no_user_turn.
        await waitForSettle()

        let claimed: DispatchGate.Proposal
        switch gate.claim(proposalId: proposalId, sessionId: sessionId) {
        case .failure(let reason):
            let active = gate.activeProposalId()
            let activeValue: Any = active ?? NSNull()
            return [
                "status": "blocked",
                "error": DispatchGate.errorText(for: reason, userName: userName),
                "active_proposal_id": activeValue,
                "instructions": DispatchGate.instructions(for: reason, activeProposalId: active),
            ]
        case .success(let proposal):
            claimed = proposal
        }

        // A cancelled submit must never reach the desktop's dispatch path.
        if !call.id.isEmpty && cancelledCalls.contains(call.id) {
            return ["status": "error", "error": "cancelled", "instructions": "Do not claim the task was sent."]
        }

        do {
            let dispatched = try await link.dispatchTask(task: claimed.task, urgency: claimed.urgency)
            onDispatch?(dispatched, claimed.task)
            return [
                "status": "started",
                "run_id": dispatched.runId,
                "origin": dispatched.origin,
                "message": dispatched.message,
                "instructions": "Say ONE short acknowledgement (e.g. 'On it — Hermes is handling that now.'). The task has only STARTED: you have NO result yet. Do not describe, predict, or summarize any outcome until SYSTEM_EVENT_HERMES_COMPLETE arrives or get_hermes_task_status returns a terminal status.",
            ]
        } catch {
            // The proposal is already consumed. The model has to stage a fresh
            // one rather than retry this id — and it must not say it was sent.
            return [
                "status": "error",
                "error": Self.dispatchErrorCode(error),
                "instructions": "Say the task could not be sent and why. Do not claim Hermes is working on it.",
            ]
        }
    }

    /// The contract's own error vocabulary, so the model repeats a real cause.
    static func dispatchErrorCode(_ error: Error) -> String {
        switch error as? LinkError {
        case .agentUnreachable: return "agent_unreachable"
        case .dispatchFailed(let detail):
            return detail.isEmpty ? "dispatch_failed" : "dispatch_failed: \(detail)"
        case .tasksUnavailable: return "tasks_unavailable"
        case .notPaired: return "not_paired"
        case .unreachable(let detail): return "mac_unreachable: \(detail)"
        case .invalidRequest(let code): return code
        case .some(let link): return link.message
        case .none: return "dispatch_failed"
        }
    }

    private func waitForSettle() async {
        guard settleTimeout > 0 else { return }
        let deadline = Date().addingTimeInterval(settleTimeout)
        while gate.isSettling(), Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(settleInterval * 1_000_000_000))
        }
    }

    // MARK: 5.4 discard_hermes_proposal

    private func discard(_ call: LiveToolCall) -> [String: Any] {
        let proposalId = call.string("proposal_id")
        switch gate.discard(proposalId: proposalId, sessionId: sessionId) {
        case .success(let proposal):
            return [
                "status": "discarded",
                "proposal_id": proposal.id,
                "instructions": "Acknowledge the decline briefly. Do not send this proposal to Hermes.",
            ]
        case .failure(let reason):
            let active = gate.activeProposalId()
            let activeValue: Any = active ?? NSNull()
            return [
                "status": "blocked",
                "error": "Could not discard the staged Hermes proposal: \(reason.rawValue).",
                "active_proposal_id": activeValue,
                "instructions": "Do not claim that a different proposal was discarded.",
            ]
        }
    }

    // MARK: 5.5 get_hermes_task_status

    private func taskStatus(_ call: LiveToolCall) async -> [String: Any] {
        let runId = call.string("run_id")
        guard !runId.isEmpty else { return Self.statusError(runId: runId, reason: "No run_id was supplied.") }
        do {
            let status = try await link.taskStatus(runId: runId)
            if let failure = status.error, !failure.isEmpty {
                return Self.statusError(runId: status.runId, reason: failure)
            }
            if status.isTerminal {
                var result: [String: Any] = [
                    "status": status.status,
                    "run_id": status.runId,
                    "instructions": "The run is finished. Report ONLY what is in `output` above — nothing else.",
                ]
                result["output"] = status.output ?? ""
                return result
            }
            return [
                "status": status.status.isEmpty ? "running" : status.status,
                "run_id": status.runId,
                "instructions": "The run is STILL IN PROGRESS. There is NO result yet. Tell the user it is still working and stop there — do not guess, predict, or invent any findings. You will receive SYSTEM_EVENT_HERMES_COMPLETE when it finishes.",
            ]
        } catch {
            return Self.statusError(runId: runId, reason: Self.describe(error))
        }
    }

    static func statusError(runId: String, reason: String) -> [String: Any] {
        [
            "status": "error",
            "run_id": runId,
            "error": reason,
            "instructions": "You could not fetch the status. Say exactly that. Do not make up a status or a result.",
        ]
    }

    // MARK: 5.6 stop_hermes_task

    private func stop(_ call: LiveToolCall) async -> [String: Any] {
        let runId = call.string("run_id")
        do {
            let status = try await link.stopTask(runId: runId)
            return ["status": status, "run_id": runId]
        } catch {
            return ["status": "error", "run_id": runId, "error": Self.describe(error)]
        }
    }

    // MARK: 5.7 approve_hermes_action

    private func approve(_ call: LiveToolCall) async -> [String: Any] {
        let runId = call.string("run_id")
        let choice = call.string("choice").lowercased()

        // The human gate lives here, not in the prompt: Iris must have
        // described the action, ended its turn, and heard the user answer.
        guard approvalGate.userAnsweredInOwnTurn else { return Self.approvalRefusedLocally() }
        guard Self.approvalChoices.contains(choice) else {
            return [
                "status": "blocked",
                "error": "\"\(choice)\" is not one of once, session, always, or deny.",
                "instructions": "Ask whether to allow this once, for this session, always, or deny it; end your turn and wait.",
            ]
        }
        guard approvalGate.claim() else { return Self.approvalRefusedLocally() }

        do {
            try await link.resolveApproval(runId: runId, decision: choice)
            return ["status": "resolved", "run_id": runId, "choice": choice]
        } catch LinkError.approvalNotPending {
            return [
                "status": "blocked",
                "error": "Hermes has no pending approval for this run.",
            ]
        } catch {
            return ["status": "error", "run_id": runId, "error": Self.describe(error)]
        }
    }

    static func approvalRefusedLocally() -> [String: Any] {
        [
            "status": "blocked",
            "error": "The user's latest complete response does not explicitly authorize that approval choice.",
            "instructions": "Ask whether to allow this once, for this session, always, or deny it; end your turn and wait.",
        ]
    }

    // MARK: 5.8 read_hermes_task_result

    private func readResult(_ call: LiveToolCall) async -> [String: Any] {
        let runId = call.string("run_id")
        do {
            let result = try await link.taskResult(runId: runId)
            return [
                "ok": true,
                "run_id": result.runId,
                "task": result.task,
                "status": result.status,
                "output": result.output,
                "instructions": result.instructions.isEmpty
                    ? "Answer only from this complete Hermes result."
                    : result.instructions,
            ]
        } catch LinkError.taskNotFinished {
            return [
                "ok": false,
                "run_id": runId,
                "error": "That Hermes run has not finished.",
                "instructions": "Say it is still working; do not invent a result.",
            ]
        } catch LinkError.taskUnknown {
            return Self.resultUnavailable(runId: runId)
        } catch LinkError.resultUnavailable {
            return Self.resultUnavailable(runId: runId)
        } catch {
            return [
                "ok": false,
                "run_id": runId,
                "error": Self.describe(error),
                "instructions": "Say the result is unavailable; do not invent its contents.",
            ]
        }
    }

    static func resultUnavailable(runId: String) -> [String: Any] {
        [
            "ok": false,
            "run_id": runId,
            "error": "The selected Hermes result could not be restored.",
            "instructions": "Say the result is unavailable; do not invent its contents.",
        ]
    }

    // MARK: Shared

    static func describe(_ error: Error) -> String {
        (error as? LinkError)?.message ?? "\(error)"
    }
}
