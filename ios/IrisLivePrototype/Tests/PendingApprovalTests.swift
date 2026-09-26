//
//  PendingApprovalTests.swift
//
//  LINK_API.md §11.5. `pending_approval` is sourced from the desktop's real
//  run state, so the decoding has exactly one job: carry what was sent, and
//  drop anything that is not a complete, answerable question rather than put
//  a blank approval in front of someone.
//

import XCTest
@testable import IrisLivePrototype

final class PendingApprovalTests: XCTestCase {

    func testDecodesTheDocumentedShape() throws {
        let approval = try XCTUnwrap(PendingApproval(json: [
            "request_id": "approval:9f3c41",
            "summary": "Hermes wants to run: rm -rf build",
            "can_approve_from_phone": true,
        ]))
        XCTAssertEqual(approval.requestId, "approval:9f3c41")
        XCTAssertEqual(approval.summary, "Hermes wants to run: rm -rf build")
        XCTAssertTrue(approval.canApproveFromPhone)
    }

    func testNullMeansNothingIsPending() {
        XCTAssertNil(PendingApproval(json: nil))
        XCTAssertNil(PendingApproval(json: NSNull()))
    }

    func testAMissingFlagIsNotPermission() throws {
        let approval = try XCTUnwrap(PendingApproval(json: [
            "request_id": "approval:1", "summary": "Needs a credential on the Mac.",
        ]))
        XCTAssertFalse(approval.canApproveFromPhone, "no buttons unless the Mac said so")
    }

    func testHalfFormedBlocksAreDropped() {
        XCTAssertNil(PendingApproval(json: ["summary": "no request id"]))
        XCTAssertNil(PendingApproval(json: ["request_id": "approval:1"]))
        XCTAssertNil(PendingApproval(json: ["request_id": "", "summary": "blank"]))
        XCTAssertNil(PendingApproval(json: ["request_id": "approval:1", "summary": "   "]))
        XCTAssertNil(PendingApproval(json: ["request_id": 5, "summary": "wrong type"]))
        XCTAssertNil(PendingApproval(json: "not an object"))
        XCTAssertNil(PendingApproval(json: [1, 2, 3]))
    }

    // MARK: On the task models

    func testAListEntryCarriesItsPendingApproval() throws {
        let task = try XCTUnwrap(LinkTask(json: [
            "run_id": "run-1",
            "task": "Goal: clear the build",
            "status": "running",
            "origin": "device:abc",
            "pending_approval": [
                "request_id": "approval:9f3c41",
                "summary": "Hermes wants to run: rm -rf build",
                "can_approve_from_phone": true,
            ],
        ]))
        XCTAssertTrue(task.needsAttention)
        XCTAssertEqual(task.pendingApproval?.requestId, "approval:9f3c41")
    }

    func testARunWithNothingPendingSaysSo() throws {
        let task = try XCTUnwrap(LinkTask(json: [
            "run_id": "run-1", "task": "t", "status": "running", "origin": "device:abc",
            "pending_approval": NSNull(),
        ]))
        XCTAssertFalse(task.needsAttention)
        XCTAssertNil(task.pendingApproval)
    }

    func testTheDetailRouteCarriesItToo() {
        let detail = LinkTaskDetail(
            json: [
                "run_id": "run-1",
                "task": "Goal: clear the build",
                "status": "running",
                "pending_approval": [
                    "request_id": "approval:2ab7e0",
                    "summary": "Hermes needs a credential entered on the Mac.",
                    "can_approve_from_phone": false,
                ],
                "step_count": 2,
            ],
            runId: "run-1",
            isDelta: false
        )
        XCTAssertEqual(detail.task.pendingApproval?.requestId, "approval:2ab7e0")
        XCTAssertFalse(detail.task.pendingApproval?.canApproveFromPhone ?? true)
    }

    // MARK: The decisions

    func testTheFourDecisionsAreTheContractsSpellings() {
        XCTAssertEqual(ApprovalDecision.allCases.map(\.rawValue), ["once", "session", "always", "deny"])
        XCTAssertTrue(ApprovalDecision.deny.isDenial)
        XCTAssertFalse(ApprovalDecision.always.isDenial)
    }

    /// A request id in a push and one in a poll are the same identifier, which
    /// is what lets the detail screen tell the user when the notification they
    /// tapped was about an earlier question.
    func testAPushAndAPollReconcileOnTheRequestId() throws {
        let pushed = try XCTUnwrap(PushNotice(userInfo: [
            "run_id": "run-1", "kind": "needs_attention",
            "request_id": "approval:9f3c41", "can_approve_from_phone": true,
        ]))
        let polled = try XCTUnwrap(PendingApproval(json: [
            "request_id": "approval:9f3c41", "summary": "…", "can_approve_from_phone": true,
        ]))
        XCTAssertEqual(pushed.requestId, polled.requestId)
    }
}
