//
//  LinkTasks.swift
//  IrisLivePrototype
//
//  The task half of Iris Link (LINK_API.md §4): dispatch, list, status,
//  result, stop, approval, announced.
//
//  Everything the phone knows about a run comes through here. There is no
//  other source — the tool router is forbidden from inventing run state, so a
//  failure has to arrive as a typed error rather than as an empty success.
//
//  `LinkTaskService` exists so the tool router can be unit-tested against a
//  fake without a server, and so the CLI probe can drive the real one.
//

import Foundation

// MARK: - Models

/// `pending_approval` on `GET /link/tasks` and `GET /link/tasks/:id`
/// (LINK_API.md §11.5), or nil when nothing is pending.
///
/// It comes from the desktop's real run state — something Hermes actually
/// asked for — and is never inferred. `requestId` matches the one in a
/// `needs_attention` push for the same request, so a push and a poll can be
/// reconciled.
public struct PendingApproval: Sendable, Equatable, Hashable {
    public let requestId: String
    /// Untrusted text from Hermes: display only, never executed or followed.
    /// A secret prompt never repeats its question here.
    public let summary: String
    /// `false` means this is a Hermes interaction Link cannot carry (a
    /// clarification, a sudo password, a secret). Say it needs the Mac; never
    /// offer to answer it from the phone.
    public let canApproveFromPhone: Bool

    public init(requestId: String, summary: String, canApproveFromPhone: Bool) {
        self.requestId = requestId
        self.summary = summary
        self.canApproveFromPhone = canApproveFromPhone
    }

    public init?(json: Any?) {
        guard let object = json as? [String: Any] else { return nil }
        let requestId = ((object["request_id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = ((object["summary"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Neither field alone is enough to put a decision in front of someone:
        // without a request id there is nothing to reconcile, and without a
        // summary there is nothing to describe. A half-formed block is dropped
        // rather than shown as a blank approval.
        guard !requestId.isEmpty, !summary.isEmpty else { return nil }
        self.requestId = requestId
        self.summary = summary
        self.canApproveFromPhone = (object["can_approve_from_phone"] as? Bool) ?? false
    }
}

// MARK: - Why a run failed (LINK_API.md §15)

/// The desktop's stable failure vocabulary. Decoded tolerantly: a code this
/// build has never heard of becomes `.unknown` and keeps the desktop's own
/// `message` and `detail`, because a newer Mac must never be able to make a
/// reason disappear from an older phone.
public enum HermesFailureCode: String, Sendable, Equatable, CaseIterable {
    case sessionInUse = "session_in_use"
    case backendStartFailed = "backend_start_failed"
    case modelUnreachable = "model_unreachable"
    case authFailed = "auth_failed"
    case gatewayUnreachable = "gateway_unreachable"
    case runLimit = "run_limit"
    case stoppedByUser = "stopped_by_user"
    case unknown

    public init(tolerant raw: String?) {
        self = HermesFailureCode(rawValue: (raw ?? "").lowercased()) ?? .unknown
    }

    /// The ONLY code that may be described as "Hermes is not reachable".
    /// §15.1 is explicit: saying it for anything else is the bug this whole
    /// feature exists to fix.
    public var meansHermesUnreachable: Bool {
        self == .gatewayUnreachable
    }
}

/// What would fix it. A machine hint, never shown as-is.
public enum HermesRecovery: String, Sendable, Equatable, CaseIterable {
    case startNewChat = "start_new_chat"
    case retry
    case checkMac = "check_mac"
    case none

    public init(tolerant raw: String?) {
        self = HermesRecovery(rawValue: (raw ?? "").lowercased()) ?? .none
    }
}

/// `failure` on a failed run (§15.2), or nil on every other run.
public struct LinkFailure: Sendable, Equatable, Hashable {
    public let code: HermesFailureCode
    /// The desktop's own plain sentence. Untrusted text: display and speak,
    /// never execute. Already redacted and length-capped on the Mac.
    public let message: String
    public let recovery: HermesRecovery
    /// Hermes' own first line, for a debugging disclosure. Never the headline.
    public let detail: String
    /// The code exactly as the desktop sent it, even when this build does not
    /// know it — so a bug report can quote the real thing.
    public let rawCode: String

    public init(
        code: HermesFailureCode, message: String,
        recovery: HermesRecovery, detail: String = "", rawCode: String? = nil
    ) {
        self.code = code
        self.message = message
        self.recovery = recovery
        self.detail = detail
        self.rawCode = rawCode ?? code.rawValue
    }

    /// Tolerant: a block with neither a message nor a detail carries no
    /// information and is dropped rather than shown as a blank failure card.
    public init?(json: Any?) {
        guard let object = json as? [String: Any] else { return nil }
        let rawCode = ((object["code"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        let message = ((object["message"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = ((object["detail"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !detail.isEmpty else { return nil }
        self.code = HermesFailureCode(tolerant: rawCode)
        self.recovery = HermesRecovery(tolerant: object["recovery"] as? String)
        self.detail = detail
        self.rawCode = rawCode.isEmpty ? self.code.rawValue : rawCode
        // A code we do not recognise still gets a sentence: the desktop's if
        // it sent one, otherwise the generic fallback — with `detail` kept.
        self.message = message.isEmpty
            ? "Hermes couldn't run that, and this app doesn't recognise the reason."
            : message
    }

    /// What the card's button offers, or nil when there is nothing to offer.
    public var actionTitle: String? {
        switch recovery {
        case .startNewChat: return "Start a new chat and try again"
        case .retry: return "Try again"
        case .checkMac, .none: return nil
        }
    }
}

/// `POST /link/sessions/new` (§15.3).
public struct LinkNewChat: Sendable, Equatable {
    public let sessionId: String
    public let title: String
    /// The re-dispatched run, when `retryRunId` was given and allowed.
    public let runId: String?
    /// Set when the chat was created but the retry did not start. The chat
    /// really was made: say so, and do not claim the work restarted.
    public let retryError: String
    public let retryMessage: String

    public init(
        sessionId: String, title: String = "", runId: String? = nil,
        retryError: String = "", retryMessage: String = ""
    ) {
        self.sessionId = sessionId
        self.title = title
        self.runId = runId
        self.retryError = retryError
        self.retryMessage = retryMessage
    }

    public var didRetry: Bool { !(runId ?? "").isEmpty }
}

/// `GET /link/tasks[?scope=all]` (§16.4).
public struct LinkTaskList: Sendable, Equatable {
    public let tasks: [LinkTask]
    /// Runs from chats that are no longer pinned. Read-only, and never news.
    public let earlier: [LinkTask]

    public init(tasks: [LinkTask], earlier: [LinkTask] = []) {
        self.tasks = tasks
        self.earlier = earlier
    }
}

/// The four answers `POST /link/tasks/:id/approval` accepts (§4).
public enum ApprovalDecision: String, Sendable, CaseIterable {
    case once
    case session
    case always
    case deny

    /// What the button says. Deliberately plain: the user is answering for a
    /// terminal-capable agent.
    public var buttonTitle: String {
        switch self {
        case .once: return "Allow once"
        case .session: return "Allow for this session"
        case .always: return "Always allow"
        case .deny: return "Deny"
        }
    }

    public var isDenial: Bool { self == .deny }
}

/// One entry of `GET /link/tasks`.
public struct LinkTask: Sendable, Equatable, Hashable, Identifiable {
    public let runId: String
    public let task: String
    public let status: String
    /// `"desktop"` or `"device:<deviceId>"`.
    public let origin: String
    public let createdAt: Double
    public let updatedAt: Double
    public let announcedAt: Double

    /// §12.1 — the desktop's own one-line "what is happening now". `""` when
    /// nothing has been recorded; never fill that in with a guess.
    public let headline: String
    /// §12.1 — steps currently retained for the run (at most 60).
    public let stepCount: Int
    /// §11.5 — what this run is waiting on, or nil.
    public let pendingApproval: PendingApproval?
    /// §15.2 — why it failed, or nil on every run that did not fail.
    public let failure: LinkFailure?
    /// §16.2 — rebuilt from the Hermes transcript rather than dispatched here.
    public let restored: Bool
    /// §16.3 — nothing on this run can be stopped, approved, or retried.
    public let readOnly: Bool
    /// Which Hermes chat it belongs to, so earlier chats can be grouped.
    public let sessionId: String

    public var id: String { runId }

    public init(
        runId: String, task: String, status: String, origin: String,
        createdAt: Double = 0, updatedAt: Double = 0, announcedAt: Double = 0,
        headline: String = "", stepCount: Int = 0,
        pendingApproval: PendingApproval? = nil,
        failure: LinkFailure? = nil,
        restored: Bool = false, readOnly: Bool = false, sessionId: String = ""
    ) {
        self.runId = runId
        self.task = task
        self.status = status
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.announcedAt = announcedAt
        self.headline = headline
        self.stepCount = stepCount
        self.pendingApproval = pendingApproval
        self.failure = failure
        self.restored = restored
        self.readOnly = readOnly
        self.sessionId = sessionId
    }

    /// True when Hermes is waiting on the user for this run.
    public var needsAttention: Bool { pendingApproval != nil }

    public var isTerminal: Bool { LinkRunStatus.isTerminal(status) }

    public var isFromThisPhone: Bool { origin.hasPrefix("device:") }

    /// History, not news: a restored or read-only run must never trigger a
    /// completion announcement, a local notification, the active-runs strip,
    /// or a Live Activity (§16.3).
    public var isHistory: Bool { restored || readOnly || origin == "history" }

    public init?(json: [String: Any]) {
        guard let runId = json["run_id"] as? String, !runId.isEmpty else { return nil }
        self.runId = runId
        self.task = (json["task"] as? String) ?? ""
        self.status = (json["status"] as? String) ?? ""
        self.origin = (json["origin"] as? String) ?? "desktop"
        self.createdAt = LinkTask.number(json["created_at"])
        self.updatedAt = LinkTask.number(json["updated_at"])
        self.announcedAt = LinkTask.number(json["announced_at"])
        self.headline = (json["headline"] as? String) ?? ""
        self.stepCount = LinkTask.integer(json["step_count"]) ?? 0
        self.pendingApproval = PendingApproval(json: json["pending_approval"])
        self.failure = LinkFailure(json: json["failure"])
        self.restored = (json["restored"] as? Bool) ?? false
        self.readOnly = (json["read_only"] as? Bool) ?? false
        self.sessionId = (json["session_id"] as? String) ?? ""
    }

    static func number(_ value: Any?) -> Double {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }
}

public enum LinkRunStatus {
    /// LINK_API.md §4: the statuses that stop polling and unlock the result.
    public static let terminal: Set<String> = ["completed", "failed", "cancelled", "canceled", "error"]

    public static func isTerminal(_ status: String) -> Bool {
        terminal.contains(status.lowercased())
    }
}

public struct LinkDispatchResult: Sendable, Equatable {
    public let status: String
    public let runId: String
    public let message: String
    public let origin: String

    public init(status: String, runId: String, message: String, origin: String) {
        self.status = status
        self.runId = runId
        self.message = message
        self.origin = origin
    }
}

/// `GET /link/tasks/:id` — the list entry merged with a live status. `output`
/// is present only for a terminal run; `error` only when the desktop itself
/// could not fetch the status.
public struct LinkTaskStatus: Sendable, Equatable {
    public let runId: String
    public let task: String
    public let origin: String
    public let status: String
    public let instructions: String
    public let output: String?
    public let error: String?
    /// §11.5 — what this run is waiting on, or nil.
    public let pendingApproval: PendingApproval?
    /// §15.2 — why it failed, or nil.
    public let failure: LinkFailure?
    /// §16.2 / §16.3.
    public let restored: Bool
    public let readOnly: Bool

    public init(
        runId: String, task: String = "", origin: String = "",
        status: String, instructions: String = "", output: String? = nil, error: String? = nil,
        pendingApproval: PendingApproval? = nil,
        failure: LinkFailure? = nil, restored: Bool = false, readOnly: Bool = false
    ) {
        self.runId = runId
        self.task = task
        self.origin = origin
        self.status = status
        self.instructions = instructions
        self.output = output
        self.error = error
        self.pendingApproval = pendingApproval
        self.failure = failure
        self.restored = restored
        self.readOnly = readOnly
    }

    public var isTerminal: Bool { LinkRunStatus.isTerminal(status) }

    public var isHistory: Bool { restored || readOnly || origin == "history" }

    /// The one decoder both status routes use, so they cannot drift.
    init(json: [String: Any], runId fallbackId: String) {
        self.runId = (json["run_id"] as? String) ?? fallbackId
        self.task = (json["task"] as? String) ?? ""
        self.origin = (json["origin"] as? String) ?? ""
        self.status = (json["status"] as? String) ?? ""
        self.instructions = (json["instructions"] as? String) ?? ""
        self.output = json["output"] as? String
        self.error = json["error"] as? String
        self.pendingApproval = PendingApproval(json: json["pending_approval"])
        self.failure = LinkFailure(json: json["failure"])
        self.restored = (json["restored"] as? Bool) ?? false
        self.readOnly = (json["read_only"] as? Bool) ?? false
    }
}

/// `GET /link/tasks/:id/result` — the complete stored output.
public struct LinkTaskResult: Sendable, Equatable {
    public let runId: String
    public let task: String
    public let status: String
    public let output: String
    public let instructions: String
    /// §15.2 — a failed run's result screen leads with WHY, not with an empty
    /// "Result" section.
    public let failure: LinkFailure?

    public init(
        runId: String, task: String, status: String, output: String,
        instructions: String, failure: LinkFailure? = nil
    ) {
        self.runId = runId
        self.task = task
        self.status = status
        self.output = output
        self.instructions = instructions
        self.failure = failure
    }
}

// MARK: - Service

/// Everything the tool router and the run tracker are allowed to ask of the
/// Mac. Implemented by `LinkClient` and by the test double.
public protocol LinkTaskService: Sendable {
    func status() async throws -> LinkStatus
    func dispatchTask(task: String, urgency: String) async throws -> LinkDispatchResult
    func listTasks(undelivered: Bool) async throws -> [LinkTask]
    func taskStatus(runId: String) async throws -> LinkTaskStatus
    /// A REQUIREMENT, not just an extension method. Callers hold this protocol
    /// as an existential; a method that exists only in an extension is
    /// statically dispatched to the extension's default, so `LinkClient`'s real
    /// implementation was never called and the phone never asked for steps.
    func taskStatus(runId: String, stepsSince: Int?) async throws -> LinkTaskDetail
    func taskResult(runId: String) async throws -> LinkTaskResult
    func stopTask(runId: String) async throws -> String
    func resolveApproval(runId: String, decision: String) async throws
    func markAnnounced(runId: String) async throws

    // ----- Live Activity and widget (LINK_API.md §14.6 / §14.7) -----
    //
    // REQUIREMENTS for the same reason as `taskStatus(runId:stepsSince:)`
    // above: `LiveActivityController` holds this protocol as an existential,
    // and a method that lives only in a protocol extension is dispatched
    // statically to that extension's default — so the real `LinkClient`
    // implementation would never run and no token would ever reach the Mac.
    // The defaults below exist only so older test doubles still compile; they
    // refuse loudly rather than succeeding quietly.

    /// `GET /link/summary` — the home-screen widget's data source.
    func summary() async throws -> LinkSummary
    /// `PUT /link/live-activity/start-token` — the per-device push-to-start token.
    func registerLiveActivityStartToken(_ token: String, environment: PushEnvironment) async throws -> Bool
    /// `DELETE /link/live-activity/start-token`.
    func unregisterLiveActivityStartToken() async throws
    /// `PUT /link/live-activity` — the per-activity update token.
    func registerLiveActivityToken(activityId: String, token: String, environment: PushEnvironment) async throws -> Bool
    /// `DELETE /link/live-activity[?activity_id=…]`. Nil clears them all.
    func unregisterLiveActivity(activityId: String?) async throws

    // ----- Failure recovery and history (LINK_API.md §15.3 / §16.4) -----
    //
    // REQUIREMENTS, for the third time and the same reason: callers hold this
    // protocol as an existential, so a method declared only in an extension is
    // dispatched statically to that extension's default and `LinkClient`'s
    // real implementation never runs. The defaults below exist only so older
    // doubles still compile, and they refuse loudly rather than quietly.

    /// `POST /link/sessions/new` — start a fresh Hermes chat and pin it,
    /// optionally re-dispatching one failed run's exact brief.
    ///
    /// There is NO tool for this and there never will be: the model must not
    /// be able to repin the user's Hermes chat. Its only caller is a
    /// deliberate, confirmed tap on the run-detail failure card.
    func startNewChat(retryRunId: String?) async throws -> LinkNewChat

    /// `GET /link/tasks?scope=all` — the pinned chat's runs plus the runs from
    /// chats that are no longer pinned.
    func listAllTasks() async throws -> LinkTaskList
}

// MARK: - LinkClient conformance

extension LinkClient: LinkTaskService {

    /// `POST /link/tasks`. The gate in `DispatchGate` MUST have been claimed
    /// before this is called — the desktop trusts the phone to have done it.
    public func dispatchTask(task: String, urgency: String) async throws -> LinkDispatchResult {
        let json = try await request(
            path: "/link/tasks",
            method: "POST",
            body: ["task": task, "urgency": urgency]
        )
        guard let runId = json["run_id"] as? String, !runId.isEmpty else {
            throw LinkError.badResponse("dispatch returned no run id")
        }
        return LinkDispatchResult(
            status: (json["status"] as? String) ?? "started",
            runId: runId,
            message: (json["message"] as? String) ?? "Hermes has started the task.",
            origin: (json["origin"] as? String) ?? ""
        )
    }

    public func listTasks(undelivered: Bool = false) async throws -> [LinkTask] {
        let json = try await request(
            path: undelivered ? "/link/tasks?undelivered=1" : "/link/tasks",
            method: "GET",
            body: nil
        )
        let raw = (json["tasks"] as? [[String: Any]]) ?? []
        return raw.compactMap(LinkTask.init(json:))
    }

    /// `GET /link/tasks?scope=all` (§16.4).
    public func listAllTasks() async throws -> LinkTaskList {
        let json = try await request(path: "/link/tasks?scope=all", method: "GET", body: nil)
        return LinkTaskList(
            tasks: ((json["tasks"] as? [[String: Any]]) ?? []).compactMap(LinkTask.init(json:)),
            // Absent means the Mac is older than §16.4, not that there are
            // none. The UI says "not available" rather than "no earlier chats".
            earlier: ((json["earlier"] as? [[String: Any]]) ?? []).compactMap(LinkTask.init(json:))
        )
    }

    /// `POST /link/sessions/new` (§15.3). Its only caller is the confirmed
    /// recovery tap; there is no tool that reaches this.
    public func startNewChat(retryRunId: String?) async throws -> LinkNewChat {
        var body: [String: Any] = [:]
        if let retryRunId, !retryRunId.isEmpty { body["retry_run_id"] = retryRunId }
        let json = try await request(path: "/link/sessions/new", method: "POST", body: body)
        guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty else {
            throw LinkError.badResponse("the Mac started no new chat")
        }
        let runId = (json["run_id"] as? String) ?? ""
        return LinkNewChat(
            sessionId: sessionId,
            title: (json["title"] as? String) ?? "",
            runId: runId.isEmpty ? nil : runId,
            retryError: (json["retry_error"] as? String) ?? "",
            retryMessage: (json["retry_message"] as? String) ?? ""
        )
    }

    public func taskStatus(runId: String) async throws -> LinkTaskStatus {
        let json = try await request(path: "/link/tasks/\(Self.segment(runId))", method: "GET", body: nil)
        return LinkTaskStatus(json: json, runId: runId)
    }

    public func taskResult(runId: String) async throws -> LinkTaskResult {
        let json = try await request(
            path: "/link/tasks/\(Self.segment(runId))/result",
            method: "GET",
            body: nil
        )
        guard (json["ok"] as? Bool) == true else {
            throw LinkError.badResponse("result was not ok")
        }
        return LinkTaskResult(
            runId: (json["run_id"] as? String) ?? runId,
            task: (json["task"] as? String) ?? "",
            status: (json["status"] as? String) ?? "",
            output: (json["output"] as? String) ?? "",
            instructions: (json["instructions"] as? String) ?? "",
            failure: LinkFailure(json: json["failure"])
        )
    }

    public func stopTask(runId: String) async throws -> String {
        let json = try await request(
            path: "/link/tasks/\(Self.segment(runId))/stop",
            method: "POST",
            body: [:]
        )
        return (json["status"] as? String) ?? "stopping"
    }

    public func resolveApproval(runId: String, decision: String) async throws {
        _ = try await request(
            path: "/link/tasks/\(Self.segment(runId))/approval",
            method: "POST",
            body: ["decision": decision]
        )
    }

    /// Called ONLY after an announcement turn has actually completed
    /// (LINK_API.md §8 step 3).
    public func markAnnounced(runId: String) async throws {
        _ = try await request(
            path: "/link/tasks/\(Self.segment(runId))/announced",
            method: "POST",
            body: [:]
        )
    }

    /// A run id is one path segment; the desktop rejects anything with a
    /// slash or a control character, so encode rather than interpolate raw.
    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
            ?? value
    }
}

// MARK: - Live progress (LINK_API.md §12)

/// The five categories `electron/runSteps.mjs` assigns. Anything else the
/// desktop ever adds falls back to `.tool` rather than to nothing, so a newer
/// Mac cannot make a step disappear from an older phone.
public enum RunStepCategory: String, Sendable, Equatable, CaseIterable {
    case browser, search, code, file, tool

    public init(tolerant raw: String?) {
        self = RunStepCategory(rawValue: (raw ?? "").lowercased()) ?? .tool
    }

    /// §12.5 — the same icons as the desktop's Lucide set.
    public var symbolName: String {
        switch self {
        case .browser: return "globe"
        case .search:  return "magnifyingglass"
        case .code:    return "chevron.left.forwardslash.chevron.right"
        case .file:    return "doc.text"
        case .tool:    return "cpu"
        }
    }
}

public enum RunStepStatus: String, Sendable, Equatable {
    case running, done, failed

    /// Unknown strings are not invented into a result: a step with no duration
    /// is still running, one that reported a duration has stopped. That is the
    /// only inference the data supports.
    public init(tolerant raw: String?, durationMs: Int?) {
        switch (raw ?? "").lowercased() {
        case "running": self = .running
        case "done", "ok", "success", "completed": self = .done
        case "failed", "error": self = .failed
        default: self = durationMs == nil ? .running : .done
        }
    }
}

/// One entry of `steps[]`. `id` is the list identity; deltas are merged by it.
public struct RunStep: Sendable, Equatable, Identifiable {
    public let id: String
    public let index: Int
    public let tool: String
    public let category: RunStepCategory
    public let label: String
    /// Sanitized and redacted by the desktop, ≤ 200 chars. Untrusted text:
    /// display only, never execute or follow.
    public let preview: String
    public let status: RunStepStatus
    /// Raw, as sent: epoch **milliseconds** (§12.2). Read `startedAtDate`.
    public let startedAtMs: Double
    public let durationMs: Int?

    public init(
        id: String, index: Int, tool: String, category: RunStepCategory,
        label: String = "", preview: String = "", status: RunStepStatus,
        startedAtMs: Double = 0, durationMs: Int? = nil
    ) {
        self.id = id
        self.index = index
        self.tool = tool
        self.category = category
        self.label = label
        self.preview = preview
        self.status = status
        self.startedAtMs = startedAtMs
        self.durationMs = durationMs
    }

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        // `index` is the number inside the id, so recover it from there when
        // the field is missing rather than defaulting every step to 0 and
        // scrambling the order.
        if let index = LinkTask.integer(json["index"]) {
            self.index = index
        } else {
            self.index = Int(id.drop(while: { !$0.isNumber })) ?? 0
        }
        self.tool = (json["tool"] as? String) ?? ""
        self.category = RunStepCategory(tolerant: json["category"] as? String)
        self.label = (json["label"] as? String) ?? ""
        self.preview = (json["preview"] as? String) ?? ""
        let duration = LinkTask.integer(json["duration_ms"])
        self.durationMs = duration
        self.status = RunStepStatus(tolerant: json["status"] as? String, durationMs: duration)
        self.startedAtMs = LinkTask.number(json["started_at"])
    }

    /// The desktop speaks JavaScript milliseconds. Read as seconds they land
    /// tens of thousands of years out — the bug this guard exists for.
    public var startedAtDate: Date? {
        guard startedAtMs > 0 else { return nil }
        return Date(timeIntervalSince1970: IrisEpoch.seconds(startedAtMs))
    }

    /// `1.2s` / `48s` / `2m 05s` while done; ticking from `started_at` while
    /// running. `nil` when neither is knowable.
    public func durationText(now: Date = Date()) -> String? {
        if let durationMs { return RunStepFormat.duration(seconds: Double(durationMs) / 1000) }
        guard status == .running, let started = startedAtDate else { return nil }
        let elapsed = now.timeIntervalSince(started)
        guard elapsed >= 0 else { return nil }
        return RunStepFormat.duration(seconds: elapsed)
    }

    /// The desktop's `prettyToolName`: `web_search` → `web search`.
    public var toolLabel: String {
        let pretty = tool
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return pretty.isEmpty ? "Step" : pretty
    }
}

/// `GET /link/tasks/:id` with §12's block attached. `isDelta` records whether
/// the request carried `steps_since`, because a full body replaces the held
/// list while a delta is merged into it.
public struct LinkTaskDetail: Sendable, Equatable {
    public let task: LinkTaskStatus
    public let headline: String
    public let stepCount: Int
    public let stepsCursor: Int
    public let stepsComplete: Bool
    public let stepsTruncated: Bool
    /// Why the Mac had no steps to give, when it says (diagnostic, not prose).
    public var stepsUnavailableReason: String = ""
    public let steps: [RunStep]
    public let isDelta: Bool

    public init(
        task: LinkTaskStatus, headline: String = "", stepCount: Int = 0,
        stepsCursor: Int = 0, stepsComplete: Bool = false, stepsTruncated: Bool = false,
        steps: [RunStep] = [], isDelta: Bool = false
    ) {
        self.task = task
        self.headline = headline
        self.stepCount = stepCount
        self.stepsCursor = stepsCursor
        self.stepsComplete = stepsComplete
        self.stepsTruncated = stepsTruncated
        self.steps = steps
        self.isDelta = isDelta
    }

    public init(json: [String: Any], runId: String, isDelta: Bool) {
        self.task = LinkTaskStatus(json: json, runId: runId)
        self.headline = (json["headline"] as? String) ?? ""
        self.stepCount = LinkTask.integer(json["step_count"]) ?? 0
        self.stepsCursor = LinkTask.integer(json["steps_cursor"]) ?? 0
        // Absent means "we cannot vouch for it", which is the honest default.
        self.stepsComplete = (json["steps_complete"] as? Bool) ?? false
        self.stepsTruncated = (json["steps_truncated"] as? Bool) ?? false
        self.steps = ((json["steps"] as? [[String: Any]]) ?? []).compactMap(RunStep.init(json:))
        self.isDelta = isDelta
        self.stepsUnavailableReason = (json["steps_unavailable_reason"] as? String) ?? ""
    }
}

extension LinkTask {
    static func integer(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

// MARK: - Progress-aware status route

public extension LinkTaskService {
    /// Default for services that predate §12 (the test double, older
    /// desktops): a status with no steps and nothing claimed about them.
    func taskStatus(runId: String, stepsSince: Int?) async throws -> LinkTaskDetail {
        LinkTaskDetail(task: try await taskStatus(runId: runId))
    }

    /// Refuses rather than pretending. A service that cannot start a new chat
    /// must not answer as though it had.
    func startNewChat(retryRunId: String?) async throws -> LinkNewChat {
        throw LinkError.tasksUnavailable
    }

    /// An older desktop has no `scope=all`; the pinned chat's list is all
    /// there is, and claiming an empty "Earlier chats" would be a lie only if
    /// we pretended it had been asked for. It has not: `earlier` is empty.
    func listAllTasks() async throws -> LinkTaskList {
        LinkTaskList(tasks: try await listTasks(undelivered: false))
    }
}

public extension LinkClient {
    /// `GET /link/tasks/:id[?steps_since=<cursor>]` (§12.2 / §12.3). This is
    /// the *same* request that carries status — §12.6 forbids polling twice.
    func taskStatus(runId: String, stepsSince: Int?) async throws -> LinkTaskDetail {
        var path = "/link/tasks/\(Self.segment(runId))"
        if let stepsSince { path += "?steps_since=\(stepsSince)" }
        let json = try await request(path: path, method: "GET", body: nil)
        return LinkTaskDetail(json: json, runId: runId, isDelta: stepsSince != nil)
    }
}
