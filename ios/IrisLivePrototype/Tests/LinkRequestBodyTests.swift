//
//  LinkRequestBodyTests.swift
//
//  What the phone actually PUTs and POSTs. These assert on the bytes, not on
//  a Swift value that was about to become bytes, because the contract is the
//  wire format: `voice` on every session mint (§13.1/§13.4), the resume ones
//  included; the push token as hex with an environment (§11.1); the approval
//  decision (§4).
//
//  A `URLProtocol` stub stands in for Iris Link — no server, no network.
//

import XCTest
@testable import IrisLivePrototype

/// Captures every request and answers it with a canned response.
final class StubProtocol: URLProtocol {

    struct Exchange {
        var status: Int = 200
        var json: [String: Any] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [(request: URLRequest, body: [String: Any])] = []
    nonisolated(unsafe) private static var next = Exchange()

    static func reset(answering: Exchange = Exchange(json: ["ok": true])) {
        lock.lock(); defer { lock.unlock() }
        recorded = []
        next = answering
    }

    static var requests: [(request: URLRequest, body: [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static var lastBody: [String: Any]? { requests.last?.body }
    static var lastRequest: URLRequest? { requests.last?.request }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves an httpBody into a stream, so read both.
        var raw = request.httpBody
        if raw == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            raw = data
        }
        let parsed = raw.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]

        Self.lock.lock()
        Self.recorded.append((request, parsed))
        let exchange = Self.next
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: exchange.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: exchange.json))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LinkRequestBodyTests: XCTestCase {

    private func client() -> LinkClient {
        LinkClient(
            baseURL: URL(string: "http://100.64.0.1:8765")!,
            credential: "test-credential",
            timeout: 5,
            protocolClasses: [StubProtocol.self]
        )
    }

    private func tokenReply(voice: String = "Algenib", purpose: String = "session", resumed: Bool = false) -> [String: Any] {
        [
            "token": "auth_tokens/abc",
            "expiresAt": "2026-09-19T12:00:00Z",
            "newSessionExpiresAt": "2026-09-19T11:31:00Z",
            "model": "models/gemini-3.1-flash-live-preview",
            "voice": voice,
            "purpose": purpose,
            "resumed": resumed,
        ]
    }

    // MARK: Token body — §13.1, §13.4

    func testAFreshSessionMintCarriesTheVoice() async throws {
        StubProtocol.reset(answering: .init(json: tokenReply()))
        let token = try await client().geminiToken(voice: "Algenib")

        let body = try XCTUnwrap(StubProtocol.lastBody)
        XCTAssertEqual(body["voice"] as? String, "Algenib")
        XCTAssertNil(body["resume_handle"], "a fresh mint has no handle")
        // `session` is the wire default; sending it changes nothing, so an
        // older desktop still sees exactly the `{}` it used to.
        XCTAssertNil(body["purpose"])
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/link/gemini-token")
        XCTAssertEqual(token.voice, "Algenib")
        XCTAssertEqual(token.purpose, "session")
    }

    /// The one that matters: a reconnect must not flip the voice mid-
    /// conversation, so the resume mint carries the same `voice` as the first.
    func testAResumeMintCarriesTheVoiceToo() async throws {
        StubProtocol.reset(answering: .init(json: tokenReply(resumed: true)))
        let token = try await client().geminiToken(resumeHandle: "handle-xyz", voice: "Algenib")

        let body = try XCTUnwrap(StubProtocol.lastBody)
        XCTAssertEqual(body["voice"] as? String, "Algenib")
        XCTAssertEqual(body["resume_handle"] as? String, "handle-xyz")
        XCTAssertTrue(token.resumed)
    }

    func testNoVoiceMeansNoVoiceField() async throws {
        StubProtocol.reset(answering: .init(json: tokenReply(voice: "Zephyr")))
        _ = try await client().geminiToken()
        let body = try XCTUnwrap(StubProtocol.lastBody)
        XCTAssertTrue(body.isEmpty, "an empty body is exactly today's behavior (§13)")
    }

    func testAPreviewMintSaysSo() async throws {
        StubProtocol.reset(answering: .init(json: tokenReply(purpose: "preview")))
        let token = try await client().geminiToken(voice: "Algenib", purpose: .preview)

        let body = try XCTUnwrap(StubProtocol.lastBody)
        XCTAssertEqual(body["purpose"] as? String, "preview")
        XCTAssertEqual(body["voice"] as? String, "Algenib")
        XCTAssertEqual(token.purpose, "preview")
    }

    func testResumedIsNeverInferredFromHavingAsked() async throws {
        // A desktop that does not implement resume_handle omits `resumed`.
        var reply = tokenReply()
        reply.removeValue(forKey: "resumed")
        StubProtocol.reset(answering: .init(json: reply))
        let token = try await client().geminiToken(resumeHandle: "handle-xyz", voice: "Algenib")
        XCTAssertFalse(token.resumed)
    }

    func testInvalidVoiceIsItsOwnError() async {
        StubProtocol.reset(answering: .init(status: 400, json: ["error": "invalid_voice"]))
        do {
            _ = try await client().geminiToken(voice: "Nope")
            XCTFail("a refused voice must not look like a success")
        } catch let error as LinkError {
            XCTAssertEqual(error, .invalidVoice)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testInvalidPurposeIsItsOwnError() async {
        StubProtocol.reset(answering: .init(status: 400, json: ["error": "invalid_purpose"]))
        do {
            _ = try await client().geminiToken(voice: "Algenib", purpose: .preview)
            XCTFail("expected a refusal")
        } catch let error as LinkError {
            XCTAssertEqual(error, .invalidPurpose)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Push token — §11.1, §11.2

    func testRegisteringSendsHexAndEnvironment() async throws {
        StubProtocol.reset(answering: .init(json: ["ok": true, "pushEnabled": true, "environment": "sandbox"]))
        let enabled = try await client().registerPushToken("0a1b2c", environment: .sandbox)

        XCTAssertTrue(enabled)
        let body = try XCTUnwrap(StubProtocol.lastBody)
        XCTAssertEqual(body["token"] as? String, "0a1b2c")
        XCTAssertEqual(body["environment"] as? String, "sandbox")
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/link/push-token")
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testUnregisteringIsABodylessDelete() async throws {
        StubProtocol.reset(answering: .init(json: ["ok": true, "pushEnabled": false]))
        try await client().unregisterPushToken()

        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/link/push-token")
        XCTAssertEqual(StubProtocol.lastBody?.isEmpty, true)
    }

    func testARefusedTokenIsReportedNotSwallowed() async {
        StubProtocol.reset(answering: .init(status: 400, json: ["error": "invalid_token"]))
        do {
            _ = try await client().registerPushToken("zzz", environment: .sandbox)
            XCTFail("expected a refusal")
        } catch let error as LinkError {
            XCTAssertEqual(error, .invalidRequest("invalid_token"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Approval — §4

    func testApprovalBodiesCarryOnlyTheDecision() async throws {
        for decision in ApprovalDecision.allCases {
            StubProtocol.reset(answering: .init(json: ["status": "resolved", "run_id": "run-1", "decision": decision.rawValue]))
            try await client().resolveApproval(runId: "run-1", decision: decision.rawValue)

            let body = try XCTUnwrap(StubProtocol.lastBody)
            XCTAssertEqual(body["decision"] as? String, decision.rawValue)
            XCTAssertEqual(body.count, 1, "nothing else belongs in an approval body")
            XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "POST")
            XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/link/tasks/run-1/approval")
        }
    }

    func testAnAlreadyResolvedApprovalIsItsOwnError() async {
        StubProtocol.reset(answering: .init(status: 409, json: ["error": "approval_not_pending"]))
        do {
            try await client().resolveApproval(runId: "run-1", decision: "once")
            XCTFail("expected a refusal")
        } catch let error as LinkError {
            XCTAssertEqual(error, .approvalNotPending)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Status — §13.3, §11

    func testStatusDecodesTheCatalogueAndPushFlag() async throws {
        StubProtocol.reset(answering: .init(json: [
            "ok": true,
            "deviceId": "d1",
            "deviceName": "Nate's iPhone",
            "hermesReachable": true,
            "userName": "Nate",
            "liveModel": "models/gemini-3.1-flash-live-preview",
            "voice": "Zephyr",
            "accent": "British (RP, London)",
            "voices": [
                ["name": "Zephyr", "style": "Bright"],
                ["name": "Algenib", "style": "Gravelly"],
                ["style": "orphaned"],
            ],
            "default_voice": "Zephyr",
            "pushConfigured": true,
        ]))
        let status = try await client().status()

        XCTAssertEqual(status.voices.map(\.name), ["Zephyr", "Algenib"], "a nameless entry is dropped")
        XCTAssertEqual(status.voices.first?.label, "Zephyr · Bright")
        XCTAssertEqual(status.defaultVoice, "Zephyr")
        XCTAssertEqual(status.accent, "British (RP, London)")
        XCTAssertTrue(status.pushConfigured)
    }

    /// A desktop that predates §13/§11 sends none of it. The phone must read
    /// that as "no catalogue, no push", not crash and not invent.
    func testStatusFromAnOlderDesktop() async throws {
        StubProtocol.reset(answering: .init(json: [
            "ok": true, "deviceId": "d1", "deviceName": "Mac", "hermesReachable": false,
            "userName": "Nate", "liveModel": "m", "voice": "Zephyr", "accent": "",
        ]))
        let status = try await client().status()
        XCTAssertTrue(status.voices.isEmpty)
        XCTAssertEqual(status.defaultVoice, "")
        XCTAssertFalse(status.pushConfigured)
    }
}
