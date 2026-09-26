//
//  IrisRunLinkTests.swift
//
//  `iris://run/<id>` (LINK_API.md §14.8). A Live Activity and a widget cannot
//  call into the app; they can only hand iOS a URL, and the run id inside it
//  came from a payload this phone did not author. So it is validated, and
//  anything that is not plainly a run id opens NOTHING — never a sanitised
//  version of itself, which would open some other run.
//

import XCTest
@testable import IrisLivePrototype

final class IrisRunLinkTests: XCTestCase {

    func testARunLinkRoundTrips() throws {
        let url = try XCTUnwrap(IrisRunLink.run("run-8f21"))
        XCTAssertEqual(url.absoluteString, "iris://run/run-8f21")
        XCTAssertEqual(IrisRunLink.parse(url), .run("run-8f21"))
    }

    func testTheOtherTwoDestinations() {
        XCTAssertEqual(IrisRunLink.parse(IrisRunLink.runs), .runs)
        XCTAssertEqual(IrisRunLink.parse(IrisRunLink.open), .app)
    }

    func testIdsTheDesktopWouldRejectAreRejectedHereToo() {
        // §14.7's alphabet: [A-Za-z0-9._:-].
        for id in ["", "run 8f21", "run/8f21", "../../etc", "run\n8f21", "run#8f21",
                   String(repeating: "a", count: 129)] {
            XCTAssertFalse(IrisRunLink.isValidRunId(id), "\(id.debugDescription) must be refused")
            XCTAssertNil(IrisRunLink.run(id))
        }
        for id in ["run-8f21", "approval:9f3c", "a.b_c-1", "A1"] {
            XCTAssertTrue(IrisRunLink.isValidRunId(id), "\(id) is a legitimate id")
        }
    }

    func testAHostileUrlOpensNothing() throws {
        for raw in ["iris://run/../../secret", "iris://run/", "iris://elsewhere",
                    "iris://run/run%20with%20spaces"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertNil(IrisRunLink.parse(url), "\(raw) must open nothing at all")
        }
    }

    func testThePairingSchemeIsNotTouched() throws {
        // `iris-link://` carries a one-time pairing secret and belongs to
        // IrisLinkDeepLink. The two parsers never see each other's URLs.
        let url = try XCTUnwrap(URL(string: "iris-link://pair?v=1&h=100.64.0.1&p=8765&s=abc"))
        XCTAssertNil(IrisRunLink.parse(url))
    }

    func testRelativeTimeIsShortAndNeverACountdown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(IrisRelativeTime.ago(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(IrisRelativeTime.ago(now.addingTimeInterval(-720), now: now), "12 min ago")
        XCTAssertEqual(IrisRelativeTime.ago(now.addingTimeInterval(-7_200), now: now), "2 h ago")
        XCTAssertEqual(IrisRelativeTime.ago(now.addingTimeInterval(-3 * 86_400), now: now), "3 d ago")
        // A clock that disagrees must not produce "in 4 s".
        XCTAssertEqual(IrisRelativeTime.ago(now.addingTimeInterval(60), now: now), "just now")
    }
}
