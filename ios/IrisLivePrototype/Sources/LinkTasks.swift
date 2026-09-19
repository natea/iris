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

/// One entry of `GET /link/tasks`.
public struct LinkTask: Sendable, Equatable, Identifiable {
    public let runId: String
    public let task: String
    public let status: String
    /// `"desktop"` or `"device:<deviceId>"`.
    public let origin: String
    public let createdAt: Double
    public let updatedAt: Double
    public let announcedAt: Double

    public var id: String { runId }

    public init(
        runId: String, task: String, status: String, origin: String,
        createdAt: Double = 0, updatedAt: Double = 0, announcedAt: Double = 0
    ) {
        self.runId = runId
        self.task = task
        self.status = status
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.announcedAt = announcedAt
    }

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
    }

    private static func number(_ value: Any?) -> Double {
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

    public init(
        runId: String, task: String = "", origin: String = "",
        status: String, instructions: String = "", output: String? = nil, error: String? = nil
    ) {
        self.runId = runId
        self.task = task
        self.origin = origin
        self.status = status
        self.instructions = instructions
        self.output = output
        self.error = error
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
            error: json["error"] as? String
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
