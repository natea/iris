//
//  PushNotificationTests.swift
//
//  LINK_API.md §11: the device token's encoding, which APNs host this build
//  belongs to, what the two payloads mean, what a malformed one must NOT do,
//  and the de-duplication that keeps one completion to one alert.
//

import XCTest
@testable import IrisLivePrototype

final class PushTokenTests: XCTestCase {

    // MARK: Hex — §11.1

    func testHexEncodingIsLowercaseAndZeroPadded() {
        let data = Data([0x00, 0x0f, 0xa1, 0xff])
        XCTAssertEqual(PushDeviceToken.hex(data), "000fa1ff")
    }

    func testHexOfARealisticTokenIs64Characters() {
        let data = Data((0..<32).map { UInt8($0) })
        let hex = PushDeviceToken.hex(data)
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(hex.prefix(6), "000102")
        // The trap this function exists for: `Data.description` is
        // "<Data 32 bytes>" on a modern OS, which the desktop refuses.
        XCTAssertFalse(hex.contains("Data"))
    }

    func testHexOfNothingIsNothing() {
        XCTAssertEqual(PushDeviceToken.hex(Data()), "")
    }

    func testRedactionNeverCarriesTheWholeToken() {
        let hex = PushDeviceToken.hex(Data((0..<32).map { UInt8($0) }))
        let redacted = PushDeviceToken.redacted(hex)
        XCTAssertFalse(redacted.contains(hex))
        XCTAssertTrue(redacted.contains("32 bytes"))
        XCTAssertEqual(PushDeviceToken.redacted("abc"), "…")
    }

    // MARK: Environment — §11.2

    func testDebugBuildsAreAlwaysSandbox() {
        XCTAssertEqual(PushEnvironment.derive(isDebugBuild: true, receiptURL: nil), .sandbox)
        XCTAssertEqual(
            PushEnvironment.derive(isDebugBuild: true, receiptURL: URL(string: "file:///r/receipt")),
            .sandbox,
            "a debug build carries the development entitlement whatever receipt is lying around"
        )
    }

    func testTestFlightIsProduction() {
        // TestFlight's receipt is named sandboxReceipt, but it uses the
        // PRODUCTION APNs host. Reading the name as the environment is the
        // classic way to make every TestFlight push fail.
        let receipt = URL(string: "file:///var/mobile/.../sandboxReceipt")
        XCTAssertEqual(PushEnvironment.derive(isDebugBuild: false, receiptURL: receipt), .production)
    }

    func testAppStoreIsProduction() {
        let receipt = URL(string: "file:///var/mobile/.../receipt")
        XCTAssertEqual(PushEnvironment.derive(isDebugBuild: false, receiptURL: receipt), .production)
    }

    func testAReleaseBuildWithNoReceiptIsStillSandbox() {
        // Run from Xcode in Release, or installed ad hoc: the profile is still
        // a development one, so the token only works against the sandbox host.
        XCTAssertEqual(PushEnvironment.derive(isDebugBuild: false, receiptURL: nil), .sandbox)
    }

    func testEnvironmentIsSentAsTheContractSpellsIt() {
        XCTAssertEqual(PushEnvironment.sandbox.rawValue, "sandbox")
        XCTAssertEqual(PushEnvironment.production.rawValue, "production")
    }
}

final class PushNoticeTests: XCTestCase {

    // MARK: The two payloads — §11.4

    func testCompletionPayload() throws {
        let notice = try XCTUnwrap(PushNotice(userInfo: [
            "aps": ["alert": ["title": "Hermes finished", "body": "Audit the dependencies"]],
            "run_id": "run-8f21a0c4d9",
            "kind": "run_complete",
        ]))
        XCTAssertEqual(notice.runId, "run-8f21a0c4d9")
        XCTAssertEqual(notice.kind, .runComplete)
        XCTAssertEqual(notice.requestId, "")
        XCTAssertFalse(notice.canApproveFromPhone, "a completion is never approvable")
    }

    func testNeedsAttentionPayload() throws {
        let notice = try XCTUnwrap(PushNotice(userInfo: [
            "aps": ["alert": ["title": "Hermes needs you", "body": "…"]],
            "run_id": "run-6d04bb92c1",
            "kind": "needs_attention",
            "request_id": "approval:9f3c41",
            "can_approve_from_phone": true,
        ]))
        XCTAssertEqual(notice.kind, .needsAttention)
        XCTAssertEqual(notice.requestId, "approval:9f3c41")
        XCTAssertTrue(notice.canApproveFromPhone)
    }

    func testAttentionThatCannotBeApprovedFromThePhone() throws {
        let notice = try XCTUnwrap(PushNotice(userInfo: [
            "run_id": "run-1", "kind": "needs_attention",
            "request_id": "approval:2", "can_approve_from_phone": false,
        ]))
        XCTAssertFalse(notice.canApproveFromPhone)
    }

    /// Absent is not permission: no field means no buttons.
    func testMissingApprovalFlagIsFalse() throws {
        let notice = try XCTUnwrap(PushNotice(userInfo: [
            "run_id": "run-1", "kind": "needs_attention", "request_id": "approval:2",
        ]))
        XCTAssertFalse(notice.canApproveFromPhone)
    }

    // MARK: Malformed — nothing is guessed

    func testMalformedPayloadsAreDropped() {
        let bad: [[AnyHashable: Any]] = [
            [:],
            ["kind": "run_complete"],                              // no run id
            ["run_id": "", "kind": "run_complete"],                // blank run id
            ["run_id": "   ", "kind": "run_complete"],
            ["run_id": "run-1"],                                   // no kind
            ["run_id": "run-1", "kind": "something_else"],         // unknown kind
            ["run_id": 42, "kind": "run_complete"],                // wrong type
            ["run_id": "run-1", "kind": 7],
            ["run_id": ["nested": "thing"], "kind": "run_complete"],
        ]
        for payload in bad {
            XCTAssertNil(PushNotice(userInfo: payload), "must not open a run from \(payload)")
        }
    }

    func testARunIdIsTrimmedNotRejected() throws {
        let notice = try XCTUnwrap(PushNotice(userInfo: ["run_id": " run-1 ", "kind": "run_complete"]))
        XCTAssertEqual(notice.runId, "run-1")
    }

    // MARK: De-duplication keys — §11.4

    func testACompletionIsOnePerRun() {
        let first = PushNotice(runId: "run-1", kind: .runComplete)
        let second = PushNotice(runId: "run-1", kind: .runComplete)
        XCTAssertEqual(first.dedupeKey, second.dedupeKey)
    }

    /// §11.4: a repeated poll of the same request does not push again, but a
    /// DIFFERENT request on the same run does — so the key is the request.
    func testAttentionIsOnePerRequestNotPerRun() {
        let first = PushNotice(runId: "run-1", kind: .needsAttention, requestId: "approval:1")
        let same = PushNotice(runId: "run-1", kind: .needsAttention, requestId: "approval:1")
        let other = PushNotice(runId: "run-1", kind: .needsAttention, requestId: "approval:2")
        XCTAssertEqual(first.dedupeKey, same.dedupeKey)
        XCTAssertNotEqual(first.dedupeKey, other.dedupeKey)
        XCTAssertNotEqual(first.dedupeKey, PushNotice(runId: "run-1", kind: .runComplete).dedupeKey)
    }
}

// MARK: - Local/push de-duplication

final class RunNotifierDedupeTests: XCTestCase {

    private func run(_ id: String, status: String = "completed", origin: String = "device:abc") -> LinkTask {
        LinkTask(runId: id, task: "Goal: something", status: status, origin: origin)
    }

    func testOnlyThisPhonesFinishedRunsAreCandidates() {
        let runs = [
            run("a"),
            run("b", status: "running"),
            run("c", origin: "desktop"),
            run("d", status: "failed"),
        ]
        let candidates = RunNotifier.candidates(from: runs, notified: [])
        XCTAssertEqual(candidates.map(\.runId), ["a", "d"])
    }

    func testTheLedgerStopsASecondBanner() {
        let candidates = RunNotifier.candidates(from: [run("a"), run("b")], notified: ["a"])
        XCTAssertEqual(candidates.map(\.runId), ["b"])
    }

    /// The case this exists for: a push arrived while the app was suspended,
    /// the app wakes, sees the finished run, and must NOT add a second alert.
    func testARunAlreadyOnScreenFromAPushIsNotNotifiedAgain() {
        let candidates = RunNotifier.candidates(
            from: [run("a"), run("b")],
            notified: [],
            alreadyOnScreen: ["a"]
        )
        XCTAssertEqual(candidates.map(\.runId), ["b"])
    }

    func testBothSuppressorsTogether() {
        let candidates = RunNotifier.candidates(
            from: [run("a"), run("b"), run("c")],
            notified: ["b"],
            alreadyOnScreen: ["a"]
        )
        XCTAssertEqual(candidates.map(\.runId), ["c"])
    }

    func testTitlesFollowTheRealTerminalStatus() {
        XCTAssertEqual(RunNotifier.title(for: "completed"), "Hermes finished")
        XCTAssertEqual(RunNotifier.title(for: "failed"), "Hermes failed")
        XCTAssertEqual(RunNotifier.title(for: "cancelled"), "Hermes run stopped")
        XCTAssertTrue(RunNotifier.title(for: "weird").contains("weird"), "never restated as success")
    }
}
