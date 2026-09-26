//
//  FakeLinkService.swift
//
//  A scripted stand-in for Iris Link. It records what the router asked for so
//  a test can assert that NOTHING reached dispatch when the gate said no.
//

import Foundation
@testable import IrisLivePrototype

actor FakeLinkService: LinkTaskService {

    struct Dispatch: Equatable {
        let task: String
        let urgency: String
    }

    // Scripted answers
    var statusResult: Result<LinkStatus, LinkError> = .success(
        LinkStatus(deviceId: "d1", deviceName: "Test iPhone", hermesReachable: true,
                   userName: "Nate", liveModel: "models/test", voice: "Zephyr", accent: "")
    )
    var dispatchResult: Result<LinkDispatchResult, LinkError> = .success(
        LinkDispatchResult(status: "started", runId: "run-1",
                           message: "Hermes has started the task.", origin: "device:d1")
    )
    var tasks: [LinkTask] = []
    var undelivered: [LinkTask] = []
    var statusByRun: [String: Result<LinkTaskStatus, LinkError>] = [:]
    var resultByRun: [String: Result<LinkTaskResult, LinkError>] = [:]
    var stopResult: Result<String, LinkError> = .success("stopping")
    var approvalResult: Result<Void, LinkError> = .success(())

    // Observations
    private(set) var dispatches: [Dispatch] = []
    private(set) var approvals: [(runId: String, decision: String)] = []
    private(set) var announced: [String] = []
    private(set) var stopped: [String] = []

    func setStatusResult(_ value: Result<LinkStatus, LinkError>) { statusResult = value }
    func setDispatchResult(_ value: Result<LinkDispatchResult, LinkError>) { dispatchResult = value }
    func setTasks(_ value: [LinkTask]) { tasks = value }
    func setUndelivered(_ value: [LinkTask]) { undelivered = value }
    func setStatus(_ value: Result<LinkTaskStatus, LinkError>, for runId: String) { statusByRun[runId] = value }
    func setResult(_ value: Result<LinkTaskResult, LinkError>, for runId: String) { resultByRun[runId] = value }
    func setStopResult(_ value: Result<String, LinkError>) { stopResult = value }
    func setApprovalResult(_ value: Result<Void, LinkError>) { approvalResult = value }

    func dispatchCount() -> Int { dispatches.count }
    func lastDispatch() -> Dispatch? { dispatches.last }
    func announcedRuns() -> [String] { announced }
    func approvalCalls() -> [(runId: String, decision: String)] { approvals }
    func stoppedRuns() -> [String] { stopped }

    // MARK: LinkTaskService

    func status() async throws -> LinkStatus { try statusResult.get() }

    func dispatchTask(task: String, urgency: String) async throws -> LinkDispatchResult {
        let outcome = dispatchResult
        // Recorded BEFORE the throw so a test can prove a failure was honest
        // rather than silent.
        dispatches.append(.init(task: task, urgency: urgency))
        return try outcome.get()
    }

    func listTasks(undelivered wantUndelivered: Bool) async throws -> [LinkTask] {
        wantUndelivered ? undelivered : tasks
    }

    func taskStatus(runId: String) async throws -> LinkTaskStatus {
        guard let scripted = statusByRun[runId] else { throw LinkError.taskUnknown }
        return try scripted.get()
    }

    func taskResult(runId: String) async throws -> LinkTaskResult {
        guard let scripted = resultByRun[runId] else { throw LinkError.taskUnknown }
        return try scripted.get()
    }

    func stopTask(runId: String) async throws -> String {
        stopped.append(runId)
        return try stopResult.get()
    }

    func resolveApproval(runId: String, decision: String) async throws {
        approvals.append((runId, decision))
        try approvalResult.get()
    }

    func markAnnounced(runId: String) async throws {
        announced.append(runId)
    }

    // MARK: Failure recovery and history (LINK_API.md §15.3 / §16.4)
    //
    // Declared here, not left to the protocol's default, because these are
    // REQUIREMENTS and the whole point is that the existential dispatches to
    // the real implementation. A test that proved only the default ran would
    // prove nothing.

    var newChatResult: Result<LinkNewChat, LinkError> = .success(
        LinkNewChat(sessionId: "api_new_1", runId: "run-retried")
    )
    var allTasks = LinkTaskList(tasks: [], earlier: [])
    /// Every `startNewChat` this double was asked for — so a test can prove a
    /// double tap made exactly ONE chat.
    private(set) var newChatCalls: [String?] = []

    func setNewChatResult(_ value: Result<LinkNewChat, LinkError>) { newChatResult = value }
    func setAllTasks(_ value: LinkTaskList) { allTasks = value }
    func newChatCallCount() -> Int { newChatCalls.count }
    func newChatRetryIds() -> [String?] { newChatCalls }

    /// A gate a test can hold shut, so two taps really do overlap.
    var newChatDelayNanoseconds: UInt64 = 0

    func setNewChatDelay(_ value: UInt64) { newChatDelayNanoseconds = value }

    func startNewChat(retryRunId: String?) async throws -> LinkNewChat {
        newChatCalls.append(retryRunId)
        if newChatDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: newChatDelayNanoseconds)
        }
        return try newChatResult.get()
    }

    func listAllTasks() async throws -> LinkTaskList { allTasks }
}
