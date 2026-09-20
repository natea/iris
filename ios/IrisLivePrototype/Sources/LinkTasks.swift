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

    public var id: String { runId }

    public init(
        runId: String, task: String, status: String, origin: String,
        createdAt: Double = 0, updatedAt: Double = 0, announcedAt: Double = 0,
        headline: String = "", stepCount: Int = 0,
        pendingApproval: PendingApproval? = nil
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
    }

    /// True when Hermes is waiting on the user for this run.
    public var needsAttention: Bool { pendingApproval != nil }

    public var isTerminal: Bool { LinkRunStatus.isTerminal(status) }

    public var isFromThisPhone: Bool { origin.hasPrefix("device:") }

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

    public init(
        runId: String, task: String = "", origin: String = "",
        status: String, instructions: String = "", output: String? = nil, error: String? = nil,
        pendingApproval: PendingApproval? = nil
    ) {
        self.runId = runId
        self.task = task
        self.origin = origin
        self.status = status
        self.instructions = instructions
        self.output = output
        self.error = error
        self.pendingApproval = pendingApproval
    }

    public var isTerminal: Bool { LinkRunStatus.isTerminal(status) }
}

/// `GET /link/tasks/:id/result` — the complete stored output.
public struct LinkTaskResult: Sendable, Equatable {
    public let runId: String
    public let task: String
    public let status: String
    public let output: String
    public let instructions: String

    public init(runId: String, task: String, status: String, output: String, instructions: String) {
        self.runId = runId
        self.task = task
        self.status = status
        self.output = output
        self.instructions = instructions
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

    public func taskStatus(runId: String) async throws -> LinkTaskStatus {
        let json = try await request(path: "/link/tasks/\(Self.segment(runId))", method: "GET", body: nil)
        return LinkTaskStatus(
            runId: (json["run_id"] as? String) ?? runId,
            task: (json["task"] as? String) ?? "",
            origin: (json["origin"] as? String) ?? "",
            status: (json["status"] as? String) ?? "",
            instructions: (json["instructions"] as? String) ?? "",
            output: json["output"] as? String,
            error: json["error"] as? String,
            pendingApproval: PendingApproval(json: json["pending_approval"])
        )
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
            instructions: (json["instructions"] as? String) ?? ""
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
        self.task = LinkTaskStatus(
            runId: (json["run_id"] as? String) ?? runId,
            task: (json["task"] as? String) ?? "",
            origin: (json["origin"] as? String) ?? "",
            status: (json["status"] as? String) ?? "",
            instructions: (json["instructions"] as? String) ?? "",
            output: json["output"] as? String,
            error: json["error"] as? String,
            pendingApproval: PendingApproval(json: json["pending_approval"])
        )
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
