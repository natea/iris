//
//  LinkLiveActivityRouteTests.swift
//
//  The four §14.7 routes and §14.6's summary, asserted on the bytes — the
//  method, the path, the query string and the JSON body — because the wire
//  format is the contract. `StubProtocol` (LinkRequestBodyTests.swift) stands
//  in for Iris Link.
//
//  Also the dispatch guard: these methods are protocol REQUIREMENTS, not
//  extension-only members. This project has already shipped that bug once —
//  `taskStatus(runId:stepsSince:)` lived only in an extension, Swift
//  dispatched it statically through `any LinkTaskService` to an empty default,
//  and the phone silently never asked the Mac for anything.
//

import XCTest
@testable import IrisLivePrototype

final class LinkLiveActivityRouteTests: XCTestCase {

    private func client() -> LinkClient {
        LinkClient(
            baseURL: URL(string: "http://100.64.0.1:8765")!,
            credential: "test-credential",
            timeout: 5,
            protocolClasses: [StubProtocol.self])
    }

    // MARK: PUT /link/live-activity

    func testTheUpdateTokenIsPutWithItsActivityIdAndEnvironment() async throws {
        StubProtocol.reset(answering: .init(json: [
            "ok": true, "activity_id": "A-1", "liveActivityEnabled": true,
        ]))
        let enabled = try await client().registerLiveActivityToken(
            activityId: "A-1", token: "ab12cd", environment: .sandbox)

        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/link/live-activity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-credential")

        let body = try XCTUnwrap(StubProtocol.lastBody)
        XCTAssertEqual(body["activity_id"] as? String, "A-1")
        XCTAssertEqual(body["token"] as? String, "ab12cd")
        XCTAssertEqual(body["environment"] as? String, "sandbox")
        XCTAssertTrue(enabled)
    }

    func testTheProductionEnvironmentIsSentVerbatim() async throws {
        StubProtocol.reset(answering: .init(json: ["ok": true, "liveActivityEnabled": true]))
        _ = try await client().registerLiveActivityToken(
            activityId: "A-1", token: "ab12cd", environment: .production)
        XCTAssertEqual(StubProtocol.lastBody?["environment"] as? String, "production")
    }

    // MARK: DELETE /link/live-activity

    func testDeletingOneActivityNamesItInTheQueryString() async throws {
        StubProtocol.reset(answering: .init(json: ["ok": true, "liveActivityEnabled": false]))
        try await client().unregisterLiveActivity(activityId: "A-1")

        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/link/live-activity")
        XCTAssertEqual(request.url?.query, "activity_id=A-1")
    }

    /// §14.7: no query string clears them all — "the user turned it off".
    func testDeletingEverythingSendsNoQueryString() async throws {
        StubProtocol.reset(answering: .init(json: ["ok": true, "liveActivityEnabled": false]))
        try await client().unregisterLiveActivity(activityId: nil)
        XCTAssertNil(StubProtocol.lastRequest?.url?.query)
    }

    /// An activity id is one query value; the desktop rejects anything with a
    /// slash or a control character, so it is encoded rather than interpolated.
    func testAnAwkwardActivityIdIsEncoded() async throws {
        StubProtocol.reset(answering: .init(json: ["ok": true, "liveActivityEnabled": false]))
        try await client().unregisterLiveActivity(activityId: "A 1/2")
        let query = try XCTUnwrap(StubProtocol.lastRequest?.url?.query)
        XCTAssertFalse(query.contains(" "))
        XCTAssertFalse(query.contains("/"))
    }

    // MARK: The push-to-start token

    func testTheStartTokenIsPutWithItsEnvironment() async throws {
        StubProtocol.reset(answering: .init(json: [
            "ok": true, "pushToStartEnabled": true, "environment": "sandbox",
        ]))
        let enabled = try await client().registerLiveActivityStartToken("ffee00", environment: .sandbox)

        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/link/live-activity/start-token")
        let body = try XCTUnwrap(StubProtocol.lastBody)
        XCTAssertEqual(body["token"] as? String, "ffee00")
        XCTAssertEqual(body["environment"] as? String, "sandbox")
        XCTAssertNil(body["activity_id"], "the start token belongs to the device, not an activity")
        XCTAssertTrue(enabled)
    }

    func testTheStartTokenIsDeletedWithNoBody() async throws {
        StubProtocol.reset(answering: .init(json: ["ok": true, "pushToStartEnabled": false]))
        try await client().unregisterLiveActivityStartToken()
        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/link/live-activity/start-token")
    }

    // MARK: GET /link/summary

    func testTheSummaryIsFetchedAndParsed() async throws {
        StubProtocol.reset(answering: .init(json: [
            "active_count": 2, "waiting_count": 1, "finished_today_count": 4,
            "active_run": ["run_id": "run-8f21", "title": "Summarize the quarterly numbers",
                           "headline": "Running code", "needs_attention": true],
            "last_finished": ["run_id": "run-7c10", "title": "Book a table",
                              "status": "completed", "finished_at": 1_758_240_301_000],
            "hermesReachable": true, "generated_at": 1_758_240_400_000,
        ]))
        let summary = try await client().summary()
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/link/summary")
        XCTAssertEqual(summary.activeCount, 2)
        XCTAssertEqual(summary.waitingCount, 1)
        XCTAssertEqual(summary.activeRun?.runId, "run-8f21")
    }

    /// `501 tasks_unavailable` — this desktop build has no summary handler.
    /// A typed refusal, so the app can stop asking rather than retry forever.
    func testAnOlderDesktopRefusesTheSummaryByName() async {
        StubProtocol.reset(answering: .init(status: 501, json: ["error": "tasks_unavailable"]))
        do {
            _ = try await client().summary()
            XCTFail("501 must not look like success")
        } catch let error as LinkError {
            XCTAssertEqual(error, .tasksUnavailable)
        } catch {
            XCTFail("wrong error type")
        }
    }

    func testAnUnknownPhoneIsToldSoOnTheTokenRoutes() async {
        StubProtocol.reset(answering: .init(status: 401, json: ["error": "not_paired"]))
        do {
            _ = try await client().registerLiveActivityStartToken("ffee00", environment: .sandbox)
            XCTFail("401 must not look like success")
        } catch let error as LinkError {
            XCTAssertEqual(error, .notPaired)
            XCTAssertTrue(error.clearsPairing)
        } catch {
            XCTFail("wrong error type")
        }
    }

    // MARK: Dispatch through the existential

    /// The regression guard. Held as `any LinkTaskService`, every one of the
    /// new methods must reach the conforming type's own implementation — not a
    /// protocol-extension default that quietly does nothing.
    func testTheNewMethodsAreDynamicallyDispatched() async throws {
        let recorder = RecordingLiveActivityService()
        let service: any LinkTaskService = recorder

        _ = try await service.registerLiveActivityToken(
            activityId: "A-1", token: "aa", environment: .sandbox)
        _ = try await service.registerLiveActivityStartToken("bb", environment: .production)
        try await service.unregisterLiveActivity(activityId: "A-1")
        try await service.unregisterLiveActivityStartToken()
        let summary = try await service.summary()

        let updates = await recorder.seenUpdateTokens()
        XCTAssertEqual(updates.count, 1, "an extension-only method would have run a default here")
        XCTAssertEqual(updates.first?.activityId, "A-1")
        let starts = await recorder.seenStartTokens()
        XCTAssertEqual(starts.first?.environment, "production")
        // Hoisted out of the assertions: `await` cannot appear inside an
        // XCTAssert autoclosure.
        let deletes = await recorder.seenDeletes()
        XCTAssertEqual(deletes, ["A-1"])
        let startDeletes = await recorder.startTokenDeletes()
        XCTAssertEqual(startDeletes, 1)
        let summaries = await recorder.summaryCallCount()
        XCTAssertEqual(summaries, 1)
        XCTAssertEqual(summary.activeCount, 1)
    }

    /// And the defaults themselves: a desktop that predates §14 refuses
    /// loudly rather than pretending a token was registered.
    func testAServiceThatPredatesSection14RefusesLoudly() async {
        let service: any LinkTaskService = FakeLinkService()
        do {
            _ = try await service.summary()
            XCTFail("the default must not fabricate a summary")
        } catch let error as LinkError {
            XCTAssertEqual(error, .tasksUnavailable)
        } catch {
            XCTFail("wrong error type")
        }
        do {
            _ = try await service.registerLiveActivityStartToken("aa", environment: .sandbox)
            XCTFail("the default must not report success")
        } catch let error as LinkError {
            XCTAssertEqual(error, .pushUnavailable)
        } catch {
            XCTFail("wrong error type")
        }
    }
}
