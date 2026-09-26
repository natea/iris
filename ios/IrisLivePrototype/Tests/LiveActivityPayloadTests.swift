//
//  LiveActivityPayloadTests.swift
//
//  The wire format, asserted against the three payloads printed in
//  LINK_API.md §14.3 — copied verbatim, byte for byte, including the key
//  order and the numbers.
//
//  This is the test that matters most in the whole feature. Apple decodes Live
//  Activity pushes with a DEFAULT `JSONDecoder` and gives no error when it
//  fails: a renamed key or a `Date` where a `Double` belongs produces an
//  activity that simply never updates, on a device, in someone's pocket. So
//  every decode here uses `JSONDecoder()` with nothing configured, exactly as
//  the system does.
//

import XCTest
@testable import IrisLivePrototype

final class LiveActivityPayloadTests: XCTestCase {

    /// The system's decoder: no date strategy, no key strategy, nothing.
    private let decoder = JSONDecoder()

    private func contentState(from payload: String) throws -> IrisRunActivityAttributes.ContentState {
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let aps = try XCTUnwrap(root["aps"] as? [String: Any])
        let state = try XCTUnwrap(aps["content-state"])
        let data = try JSONSerialization.data(withJSONObject: state)
        return try decoder.decode(IrisRunActivityAttributes.ContentState.self, from: data)
    }

    // MARK: §14.3 — start

    private let startPayload = """
    {
      "aps": {
        "timestamp": 1789870577,
        "event": "start",
        "content-state": {
          "status": "running", "headline": "Running code",
          "title": "Summarize the quarterly numbers", "detail": "python analyze.py",
          "stepCount": 3, "stepsKnown": true, "activeRunCount": 1,
          "needsAttention": false, "attentionSummary": "",
          "runs": [{ "id": "run-8f21", "title": "Summarize the quarterly numbers", "status": "running", "headline": "Running code" }],
          "startedAt": 1789870500, "updatedAt": 1789870577
        },
        "attributes-type": "IrisRunActivityAttributes",
        "attributes": { "title": "Hermes", "macName": "studio", "deviceId": "8d153b5d" },
        "stale-date": 1789870697,
        "relevance-score": 100,
        "input-push-token": 1,
        "alert": { "title": "Hermes is working", "body": "Summarize the quarterly numbers", "sound": "default" }
      }
    }
    """

    func testTheStartPayloadDecodesWithADefaultDecoder() throws {
        let state = try contentState(from: startPayload)
        XCTAssertEqual(state.status, "running")
        XCTAssertEqual(state.headline, "Running code")
        XCTAssertEqual(state.title, "Summarize the quarterly numbers")
        XCTAssertEqual(state.detail, "python analyze.py")
        XCTAssertEqual(state.stepCount, 3)
        XCTAssertTrue(state.stepsKnown)
        XCTAssertEqual(state.activeRunCount, 1)
        XCTAssertFalse(state.needsAttention)
        XCTAssertEqual(state.attentionSummary, "")
        XCTAssertEqual(state.runs.count, 1)
        XCTAssertEqual(state.runs.first?.id, "run-8f21")
        XCTAssertEqual(state.runs.first?.status, "running")
        XCTAssertEqual(state.runs.first?.headline, "Running code")
        XCTAssertEqual(state.startedAt, 1_789_870_500)
        XCTAssertEqual(state.updatedAt, 1_789_870_577)
    }

    /// The bug the contract spends a paragraph on: a default decoder reads a
    /// `Date` as seconds since 2001, so a `Date`-typed field would land 31
    /// years early and nothing would report an error. Declared as `Double`,
    /// the same number is the epoch second it actually is.
    func testTimestampsAreEpochSecondsAndNotAppleReferenceDates() throws {
        let state = try contentState(from: startPayload)
        let started = try XCTUnwrap(state.startedAtDate)
        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(identifier: "UTC")!, from: started)
        XCTAssertEqual(components.year, 2026, "epoch seconds must not be read as a 2001 reference date")

        // And the failure mode itself, spelled out: the same number read the
        // wrong way is decades off.
        let wrong = Date(timeIntervalSinceReferenceDate: state.startedAt)
        XCTAssertGreaterThan(
            abs(started.timeIntervalSince(wrong)), 60 * 60 * 24 * 365 * 30,
            "the two readings differ by ~31 years — this is why the field is a Double")
    }

    // MARK: §14.3 — update

    func testTheUpdatePayloadDecodesWithADefaultDecoder() throws {
        let state = try contentState(from: """
        {
          "aps": {
            "timestamp": 1789870620,
            "event": "update",
            "content-state": {
              "status": "waiting", "headline": "Running code",
              "title": "Deploy the site", "detail": "rm -rf build",
              "stepCount": 7, "stepsKnown": true, "activeRunCount": 2,
              "needsAttention": true, "attentionSummary": "Hermes wants to run: rm -rf build",
              "runs": [
                { "id": "run-9a02", "title": "Deploy the site", "status": "waiting", "headline": "Running code" },
                { "id": "run-8f21", "title": "Summarize the quarterly numbers", "status": "running", "headline": "Searching example.com" }
              ],
              "startedAt": 1789870540, "updatedAt": 1789870620
            },
            "stale-date": 1789870740,
            "relevance-score": 100,
            "alert": { "title": "Hermes needs you", "body": "Hermes wants to run: rm -rf build", "sound": "default" }
          }
        }
        """)
        XCTAssertEqual(state.status, "waiting")
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertTrue(state.needsAttention)
        XCTAssertEqual(state.attentionSummary, "Hermes wants to run: rm -rf build")
        XCTAssertEqual(state.activeRunCount, 2)
        XCTAssertEqual(state.runs.map(\.id), ["run-9a02", "run-8f21"])
        XCTAssertEqual(state.runs.map(\.status), ["waiting", "running"])
        XCTAssertEqual(state.stepText, "7 steps")
    }

    // MARK: §14.3 — end

    func testTheEndPayloadDecodesAndKeepsTheRealTerminalStatus() throws {
        let state = try contentState(from: """
        {
          "aps": {
            "timestamp": 1789870900,
            "event": "end",
            "content-state": {
              "status": "failed", "headline": "", "title": "Deploy the site", "detail": "",
              "stepCount": 0, "stepsKnown": false, "activeRunCount": 0,
              "needsAttention": false, "attentionSummary": "", "runs": [],
              "startedAt": 1789870540, "updatedAt": 1789870900
            },
            "dismissal-date": 1789872700
          }
        }
        """)
        XCTAssertEqual(state.phase, .failed, "`failed` is the real status and is never softened")
        XCTAssertTrue(state.phase.isTerminal)
        XCTAssertEqual(state.runs, [])
        XCTAssertEqual(state.activeRunCount, 0)

        // Truthfulness rules 2 and 3, at the point they are decided.
        XCTAssertNil(state.stepText, "stepsKnown:false must produce no step text at all")
        XCTAssertEqual(state.headlineOrStatus, "Couldn't finish",
                       "an empty headline shows the status, never a guess")
    }

    // MARK: attributes-type

    /// `attributes-type` in every push is this exact string. ActivityKit
    /// matches the payload to the activity by it and silently drops anything
    /// that does not match, so renaming the Swift type breaks every push.
    func testTheAttributesTypeNameMatchesTheContract() {
        XCTAssertEqual(String(describing: IrisRunActivityAttributes.self), "IrisRunActivityAttributes")
    }

    func testAttributesEncodeWithTheContractsKeys() throws {
        let attributes = IrisRunActivityAttributes(macName: "studio", deviceId: "8d153b5d")
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(attributes)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["title", "macName", "deviceId"])
        XCTAssertEqual(json["title"] as? String, "Hermes")
        XCTAssertEqual(json["macName"] as? String, "studio")
        XCTAssertEqual(json["deviceId"] as? String, "8d153b5d")
    }

    /// The Mac's `attributes` object must decode into the phone's type too —
    /// that is what a push-to-start does.
    func testTheContractsAttributesObjectDecodes() throws {
        let data = Data(#"{ "title": "Hermes", "macName": "studio", "deviceId": "8d153b5d" }"#.utf8)
        let attributes = try decoder.decode(IrisRunActivityAttributes.self, from: data)
        XCTAssertEqual(attributes.macName, "studio")
        XCTAssertEqual(attributes.deviceId, "8d153b5d")
        XCTAssertEqual(attributes.title, "Hermes")
    }

    /// A round trip through the system's own default coders, which is what
    /// happens on every local update.
    func testTheStateRoundTripsThroughDefaultCoders() throws {
        let original = IrisRunActivityAttributes.ContentState.preview(.needsAttention)
        let decoded = try decoder.decode(
            IrisRunActivityAttributes.ContentState.self,
            from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
