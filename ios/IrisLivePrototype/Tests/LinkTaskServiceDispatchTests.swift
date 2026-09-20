import XCTest
@testable import IrisLivePrototype

/// Guards a bug found on device: the steps-aware status call lived only in a
/// protocol extension, so through `any LinkTaskService` Swift always ran the
/// extension's empty default and the run screen never received a step.
final class LinkTaskServiceDispatchTests: XCTestCase {
    private struct StepsService: LinkTaskService {
        func status() async throws -> LinkStatus { throw LinkError.unreachable("unused") }
        func dispatchTask(task: String, urgency: String) async throws -> LinkDispatchResult { throw LinkError.unreachable("unused") }
        func listTasks(undelivered: Bool) async throws -> [LinkTask] { [] }
        func taskStatus(runId: String) async throws -> LinkTaskStatus {
            LinkTaskStatus(runId: runId, task: "t", origin: "", status: "completed", instructions: "", output: nil, error: nil, pendingApproval: nil)
        }
        func taskStatus(runId: String, stepsSince: Int?) async throws -> LinkTaskDetail {
            LinkTaskDetail(json: [
                "run_id": runId, "status": "completed", "step_count": 1, "steps_cursor": 1, "steps_complete": true,
                "steps": [["id": "s1", "index": 1, "tool": "execute_code", "category": "code", "label": "Execute Code",
                           "preview": "import os", "status": "done", "started_at": 0, "duration_ms": 100]],
            ], runId: runId, isDelta: stepsSince != nil)
        }
        func taskResult(runId: String) async throws -> LinkTaskResult { throw LinkError.unreachable("unused") }
        func stopTask(runId: String) async throws -> String { "" }
        func resolveApproval(runId: String, decision: String) async throws {}
        func markAnnounced(runId: String) async throws {}
    }

    func testStepsAwareStatusIsDynamicallyDispatchedThroughTheProtocol() async throws {
        let service: any LinkTaskService = StepsService()
        let detail = try await service.taskStatus(runId: "r", stepsSince: nil)
        XCTAssertEqual(detail.steps.count, 1, "the conforming type's implementation must be the one called")
        XCTAssertTrue(detail.stepsComplete)
    }
}
