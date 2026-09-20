//
//  WidgetSnapshotTests.swift
//
//  The home-screen widget's data path (LINK_API.md §14.6): the summary route's
//  shape, the snapshot the app writes into the App Group container, and the
//  age thresholds that are the whole difference between a widget and the Live
//  Activity.
//
//  The credential never appears here, and that is the design: the snapshot is
//  counts, two titles and a flag, because the extension must be able to read
//  it without being trusted with anything.
//

import XCTest
@testable import IrisLivePrototype

final class WidgetSnapshotTests: XCTestCase {

    // MARK: GET /link/summary

    /// §14.6's example body, verbatim.
    private let body: [String: Any] = [
        "active_count": 2,
        "waiting_count": 1,
        "finished_today_count": 4,
        "active_run": [
            "run_id": "run-8f21",
            "title": "Summarize the quarterly numbers",
            "headline": "Running code",
            "needs_attention": true,
        ],
        "last_finished": [
            "run_id": "run-7c10",
            "title": "Book a table",
            "status": "completed",
            "finished_at": 1_758_240_301_000,
        ],
        "hermesReachable": true,
        "generated_at": 1_758_240_400_000,
    ]

    func testTheSummaryRouteIsParsedFieldForField() {
        let summary = LinkSummary(json: body)
        XCTAssertEqual(summary.activeCount, 2)
        XCTAssertEqual(summary.waitingCount, 1)
        XCTAssertEqual(summary.finishedTodayCount, 4)
        XCTAssertEqual(summary.activeRun?.runId, "run-8f21")
        XCTAssertEqual(summary.activeRun?.headline, "Running code")
        XCTAssertEqual(summary.activeRun?.needsAttention, true)
        XCTAssertEqual(summary.lastFinished?.status, "completed")
        XCTAssertTrue(summary.hermesReachable)
    }

    func testAnAbsentRunIsNilRatherThanAnEmptyOne() {
        let summary = LinkSummary(json: [
            "active_count": 0, "waiting_count": 0, "finished_today_count": 0,
            "active_run": NSNull(), "last_finished": NSNull(),
            "hermesReachable": false, "generated_at": 1_758_240_400_000,
        ])
        XCTAssertNil(summary.activeRun)
        XCTAssertNil(summary.lastFinished)
        XCTAssertEqual(summary.phaseIsIdle, true)
    }

    func testMillisecondsBecomeSecondsExactlyOnce() {
        let snapshot = LinkSummary(json: body).snapshot(
            macName: "studio",
            now: Date(timeIntervalSince1970: 1_758_240_400)
        )
        XCTAssertEqual(snapshot.generatedAt, 1_758_240_400, accuracy: 0.001)
        XCTAssertEqual(snapshot.lastFinished?.finishedAt ?? 0, 1_758_240_301, accuracy: 0.001)
        XCTAssertTrue(snapshot.paired)
        XCTAssertEqual(snapshot.macName, "studio")
    }

    // MARK: The snapshot itself

    func testTheSnapshotSurvivesAJSONRoundTrip() throws {
        let original = IrisWidgetSnapshot.preview(.waiting)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(IrisWidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testTheSnapshotCarriesNoCredentialAndNoOutput() throws {
        let data = try JSONEncoder().encode(IrisWidgetSnapshot.preview(.waiting))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for forbidden in ["credential", "token", "output", "steps", "secret"] {
            XCTAssertFalse(json.keys.contains(where: { $0.lowercased().contains(forbidden) }),
                           "the shared snapshot must never carry \(forbidden)")
        }
    }

    // MARK: Age

    func testFreshDataSaysNothingAboutItsAge() {
        let now = Date()
        let snapshot = IrisWidgetSnapshot(paired: true, generatedAt: now.timeIntervalSince1970 - 30)
        XCTAssertEqual(snapshot.freshness(now: now), .current)
        XCTAssertNil(snapshot.ageLine(now: now))
        XCTAssertFalse(snapshot.isStale(now: now))
    }

    func testOlderDataIsShownWithItsAge() {
        let now = Date()
        let snapshot = IrisWidgetSnapshot(
            paired: true, generatedAt: now.timeIntervalSince1970 - (12 * 60))
        guard case .aging = snapshot.freshness(now: now) else {
            return XCTFail("twelve minutes is past the aging threshold")
        }
        XCTAssertEqual(snapshot.ageLine(now: now), "as of 12 min ago")
        XCTAssertFalse(snapshot.isStale(now: now))
    }

    func testDataTooOldToStandBehindAsksForTheApp() {
        let now = Date()
        let snapshot = IrisWidgetSnapshot(
            paired: true, generatedAt: now.timeIntervalSince1970 - (IrisWidgetSnapshot.staleAfter + 60))
        XCTAssertTrue(snapshot.isStale(now: now))
        XCTAssertEqual(snapshot.ageLine(now: now), "Open Iris to refresh")
    }

    func testASnapshotThatWasNeverGeneratedIsStaleRatherThanCurrent() {
        let snapshot = IrisWidgetSnapshot(paired: true, generatedAt: 0)
        XCTAssertTrue(snapshot.isStale())
        XCTAssertNil(snapshot.generatedAtDate)
    }

    func testTheThresholdsAreTheOnesTheViewsAssume() {
        XCTAssertEqual(IrisWidgetSnapshot.agingAfter, 3 * 60)
        XCTAssertEqual(IrisWidgetSnapshot.staleAfter, 45 * 60)
    }

    // MARK: Phase

    func testAWaitingRunOutranksARunningOne() {
        XCTAssertEqual(IrisWidgetSnapshot(paired: true, activeCount: 2, waitingCount: 1).phase, .waiting)
        XCTAssertEqual(IrisWidgetSnapshot(paired: true, activeCount: 2, waitingCount: 0).phase, .running)
        XCTAssertEqual(IrisWidgetSnapshot(paired: true).phase, .idle)
    }

    func testAFinishedRunKeepsItsRealStatus() {
        XCTAssertEqual(IrisWidgetSnapshot.terminalPhase("completed"), .done)
        XCTAssertEqual(IrisWidgetSnapshot.terminalPhase("failed"), .failed)
        XCTAssertEqual(IrisWidgetSnapshot.terminalPhase("error"), .failed)
        XCTAssertEqual(IrisWidgetSnapshot.terminalPhase("cancelled"), .stopped)
        XCTAssertEqual(IrisWidgetSnapshot.terminalPhase("canceled"), .stopped)
    }

    // MARK: The shared container

    func testTheStoreRoundTripsThroughAFileTheExtensionCouldRead() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = IrisWidgetStore(directory: directory)
        XCTAssertTrue(store.isAvailable)
        XCTAssertNil(store.load())

        let snapshot = IrisWidgetSnapshot.preview(.active)
        XCTAssertTrue(store.save(snapshot))
        XCTAssertEqual(store.load(), snapshot)

        store.clear()
        XCTAssertNil(store.load())
    }

    func testAMissingContainerDegradesToNoDataRatherThanCrashing() {
        // What a device without the App Group provisioned looks like.
        let store = IrisWidgetStore(directory: nil)
        XCTAssertFalse(store.isAvailable)
        XCTAssertNil(store.load())
        XCTAssertFalse(store.save(.preview(.active)))
    }
}

private extension LinkSummary {
    var phaseIsIdle: Bool { activeCount == 0 && waitingCount == 0 }
}
