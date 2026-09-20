//
//  LiveActivityControllerTests.swift
//
//  The lifecycle, with ActivityKit replaced by a fake. Three things are being
//  guarded here, all of them things that fail silently in production:
//
//    1. The push-to-start adoption path (LINK_API.md §14.8). An activity the
//       Mac raises while Iris is closed sits on the lock screen and CANNOT be
//       updated until this app registers its update token, so adoption and
//       registration have to happen at launch, before any view exists.
//    2. Every token reaching the Mac through `any LinkTaskService`. The
//       registration methods are protocol REQUIREMENTS for exactly the reason
//       LinkTaskServiceDispatchTests records: an extension-only method is
//       dispatched statically to its default and never calls the network.
//    3. "Off" meaning off — ending the activity and DELETEing the tokens.
//

import XCTest
@testable import IrisLivePrototype

// MARK: - Doubles

@MainActor
final class FakeLiveActivitySource: LiveActivitySource {

    weak var delegate: (any LiveActivitySourceDelegate)?
    var areActivitiesEnabled = true
    var runningActivityId: String?

    private(set) var didBegin = false
    private(set) var requested: [IrisRunActivityAttributes.ContentState] = []
    private(set) var updates: [(id: String, state: IrisRunActivityAttributes.ContentState, alert: Bool)] = []
    private(set) var ends: [(id: String, state: IrisRunActivityAttributes.ContentState, dismissAfter: TimeInterval)] = []
    /// Set to make `request` throw, the way iOS refuses over budget.
    var requestError: Error?
    var nextActivityId = "activity-1"

    func begin() { didBegin = true }

    func request(
        attributes: IrisRunActivityAttributes,
        state: IrisRunActivityAttributes.ContentState,
        staleDate: Date
    ) throws -> String {
        if let requestError { throw requestError }
        requested.append(state)
        runningActivityId = nextActivityId
        return nextActivityId
    }

    func update(
        id: String,
        state: IrisRunActivityAttributes.ContentState,
        staleDate: Date,
        alert: (title: String, body: String)?
    ) {
        updates.append((id, state, alert != nil))
    }

    func end(id: String, state: IrisRunActivityAttributes.ContentState, dismissAfter: TimeInterval) {
        ends.append((id, state, dismissAfter))
        runningActivityId = nil
    }
}

/// Records what reached the Mac. Deliberately reached through
/// `any LinkTaskService`, which is the dispatch the app itself uses.
actor RecordingLiveActivityService: LinkTaskService {

    private(set) var updateTokens: [(activityId: String, token: String, environment: String)] = []
    private(set) var startTokens: [(token: String, environment: String)] = []
    private(set) var deletedActivities: [String?] = []
    private(set) var deletedStartTokens = 0
    private(set) var summaryCalls = 0

    // Accessors, because an actor's stored properties cannot be read
    // synchronously from a test.
    func seenUpdateTokens() -> [(activityId: String, token: String, environment: String)] { updateTokens }
    func seenStartTokens() -> [(token: String, environment: String)] { startTokens }
    func seenDeletes() -> [String] { deletedActivities.compactMap { $0 } }
    func startTokenDeletes() -> Int { deletedStartTokens }
    func summaryCallCount() -> Int { summaryCalls }

    func registerLiveActivityToken(activityId: String, token: String, environment: PushEnvironment) async throws -> Bool {
        updateTokens.append((activityId, token, environment.rawValue))
        return true
    }

    func registerLiveActivityStartToken(_ token: String, environment: PushEnvironment) async throws -> Bool {
        startTokens.append((token, environment.rawValue))
        return true
    }

    func unregisterLiveActivity(activityId: String?) async throws {
        deletedActivities.append(activityId)
    }

    func unregisterLiveActivityStartToken() async throws { deletedStartTokens += 1 }

    // The rest of the task API is not exercised here.
    func status() async throws -> LinkStatus { throw LinkError.unreachable("unused") }
    func dispatchTask(task: String, urgency: String) async throws -> LinkDispatchResult { throw LinkError.unreachable("unused") }
    func listTasks(undelivered: Bool) async throws -> [LinkTask] { [] }
    func taskStatus(runId: String) async throws -> LinkTaskStatus { throw LinkError.taskUnknown }
    func taskResult(runId: String) async throws -> LinkTaskResult { throw LinkError.taskUnknown }
    func stopTask(runId: String) async throws -> String { "" }
    func resolveApproval(runId: String, decision: String) async throws {}
    func markAnnounced(runId: String) async throws {}
    func summary() async throws -> LinkSummary {
        summaryCalls += 1
        return LinkSummary(
            activeCount: 1, waitingCount: 0, finishedTodayCount: 0,
            activeRun: nil, lastFinished: nil,
            hermesReachable: true, generatedAtMs: 1_758_240_400_000
        )
    }
}

// MARK: - Tests

@MainActor
final class LiveActivityControllerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "iris.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let paired = PairedDesktop(
        host: "100.64.0.1", port: 8765, deviceId: "d1",
        credential: "cred", desktopName: "studio"
    )

    private func makeController(
        source: FakeLiveActivitySource,
        service: RecordingLiveActivityService
    ) -> LiveActivityController {
        let controller = LiveActivityController(
            source: source, environment: .sandbox, defaults: defaults)
        controller.makeService = { _ in service }
        controller.configure(paired: paired)
        return controller
    }

    private func run(
        _ id: String, status: String = "running", origin: String = "device:d1",
        approval: PendingApproval? = nil
    ) -> LinkTask {
        LinkTask(runId: id, task: "Deploy the site", status: status, origin: origin,
                 createdAt: 1_700_000_000_000, updatedAt: 1_700_000_060_000,
                 headline: "Running code", stepCount: 3, pendingApproval: approval)
    }

    /// The registrations happen in detached tasks; wait for the recorder
    /// rather than sleeping a fixed amount.
    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(message, file: file, line: line)
    }

    // MARK: Push-to-start adoption

    func testAnActivityStartedByPushIsAdoptedAndItsTokenIsRegistered() async {
        let source = FakeLiveActivitySource()
        // The Mac push-started this while Iris was closed.
        source.runningActivityId = "activity-from-push"
        let service = RecordingLiveActivityService()
        let controller = makeController(source: source, service: service)

        controller.begin()
        XCTAssertTrue(source.didBegin)
        XCTAssertEqual(controller.activityId, "activity-from-push",
                       "a push-started activity must be adopted at launch")

        // ActivityKit hands the app a fresh update token moments later.
        controller.liveActivity(didReceiveUpdateToken: "ab12cd34ef56", activityId: "activity-from-push")
        await waitUntil({ await service.updateTokens.count == 1 },
                        "the adopted activity's update token must reach the Mac")
        let sent = await service.updateTokens[0]
        XCTAssertEqual(sent.activityId, "activity-from-push")
        XCTAssertEqual(sent.token, "ab12cd34ef56")
        XCTAssertEqual(sent.environment, "sandbox")
        XCTAssertFalse(controller.tokenSummary.contains("ab12cd34ef56"),
                       "a token is never shown whole")
    }

    func testAChangedUpdateTokenIsReSentAndAnIdenticalOneIsNot() async {
        let source = FakeLiveActivitySource()
        let service = RecordingLiveActivityService()
        let controller = makeController(source: source, service: service)

        controller.liveActivity(didReceiveUpdateToken: "aaaa1111", activityId: "a1")
        await waitUntil({ await service.updateTokens.count == 1 }, "first token")
        controller.liveActivity(didReceiveUpdateToken: "aaaa1111", activityId: "a1")
        controller.liveActivity(didReceiveUpdateToken: "bbbb2222", activityId: "a1")
        await waitUntil({ await service.updateTokens.count == 2 },
                        "a rotated token must replace the dead one")
        let tokens = await service.updateTokens.map(\.token)
        XCTAssertEqual(tokens, ["aaaa1111", "bbbb2222"])
    }

    func testThePushToStartTokenIsRegisteredWithoutAnyActivityRunning() async {
        let source = FakeLiveActivitySource()
        let service = RecordingLiveActivityService()
        let controller = makeController(source: source, service: service)

        controller.liveActivity(didReceiveStartToken: "99887766")
        await waitUntil({ await service.startTokens.count == 1 },
                        "the push-to-start token does not need an activity")
        XCTAssertNil(controller.activityId)
        let sent = await service.startTokens[0]
        XCTAssertEqual(sent.environment, "sandbox")
    }

    // MARK: Start / update / end

    func testADeviceRunStartsOneActivityAndTheNextRunOnlyUpdatesIt() async {
        let source = FakeLiveActivitySource()
        let controller = makeController(source: source, service: RecordingLiveActivityService())

        controller.observe(runs: [run("run-1")])
        XCTAssertEqual(source.requested.count, 1)
        XCTAssertEqual(controller.activityId, "activity-1")

        controller.observe(runs: [run("run-1"), run("run-2")])
        XCTAssertEqual(source.requested.count, 1, "§14.1: one summary activity, never one per run")
        XCTAssertEqual(source.updates.count, 1)
        XCTAssertEqual(source.updates.last?.state.activeRunCount, 2)
    }

    func testTheActivityEndsWithTheRealStatusWhenTheLastRunFinishes() async {
        let source = FakeLiveActivitySource()
        let service = RecordingLiveActivityService()
        let controller = makeController(source: source, service: service)

        controller.observe(runs: [run("run-1")])
        controller.observe(runs: [run("run-1", status: "failed")])

        XCTAssertEqual(source.ends.count, 1)
        XCTAssertEqual(source.ends.last?.state.status, "failed")
        XCTAssertEqual(source.ends.last?.dismissAfter, 30 * 60)
        XCTAssertNil(controller.activityId)
        await waitUntil({ await service.deletedActivities.contains("activity-1") },
                        "an ended activity's token must be DELETEd")
    }

    func testNothingIsStartedWhileTheFeatureIsOff() async {
        let source = FakeLiveActivitySource()
        let controller = makeController(source: source, service: RecordingLiveActivityService())
        controller.setEnabled(false)

        controller.observe(runs: [run("run-1")])
        XCTAssertTrue(source.requested.isEmpty)
        XCTAssertNil(controller.activityId)
    }

    func testNothingIsStartedWhenIOSHasLiveActivitiesOff() async {
        let source = FakeLiveActivitySource()
        source.areActivitiesEnabled = false
        let controller = makeController(source: source, service: RecordingLiveActivityService())

        controller.observe(runs: [run("run-1")])
        XCTAssertTrue(source.requested.isEmpty)
        XCTAssertFalse(controller.systemAllows)
        XCTAssertEqual(controller.stateLabel, "Turned off in iOS Settings")
    }

    func testTurningItOffEndsTheActivityAndClearsEveryTokenOnTheMac() async {
        let source = FakeLiveActivitySource()
        let service = RecordingLiveActivityService()
        let controller = makeController(source: source, service: service)

        controller.liveActivity(didReceiveStartToken: "99887766")
        controller.observe(runs: [run("run-1")])
        XCTAssertNotNil(controller.activityId)

        controller.setEnabled(false)
        XCTAssertEqual(source.ends.last?.dismissAfter, 0, "the user asked for it off their lock screen now")
        XCTAssertNil(controller.activityId)
        XCTAssertEqual(controller.tokenSummary, "")
        // §14.7: DELETE with no query string clears them all.
        await waitUntil({ await service.deletedActivities.contains(where: { $0 == nil }) },
                        "every activity token must be cleared")
        await waitUntil({ await service.deletedStartTokens >= 1 },
                        "the push-to-start token must be cleared too")
    }

    func testTheSwitchIsRemembered() {
        let source = FakeLiveActivitySource()
        let first = makeController(source: source, service: RecordingLiveActivityService())
        XCTAssertTrue(first.isEnabled, "on by default")
        first.setEnabled(false)

        let second = LiveActivityController(source: FakeLiveActivitySource(), defaults: defaults)
        XCTAssertFalse(second.isEnabled)
    }

    func testAStaleActivityIsReportedRatherThanLeftLookingBusy() async {
        let source = FakeLiveActivitySource()
        let controller = makeController(source: source, service: RecordingLiveActivityService())
        controller.observe(runs: [run("run-1")])

        controller.liveActivity(didChangeStale: true, activityId: "activity-1")
        XCTAssertTrue(controller.isStale)
        XCTAssertEqual(controller.stateLabel, "Running · your Mac stopped reporting")
    }

    func testARefusedStartIsSaidOutLoudRatherThanRetriedSilently() async {
        let source = FakeLiveActivitySource()
        source.requestError = LinkError.unreachable("budget")
        let controller = makeController(source: source, service: RecordingLiveActivityService())

        controller.observe(runs: [run("run-1")])
        XCTAssertNil(controller.activityId)
        XCTAssertNotNil(controller.problem)
    }

    func testUnpairingEndsTheActivityAndUnregistersWhileTheCredentialStillWorks() async {
        let source = FakeLiveActivitySource()
        let service = RecordingLiveActivityService()
        let controller = makeController(source: source, service: service)
        controller.observe(runs: [run("run-1")])

        await controller.unpairing()
        XCTAssertNil(controller.activityId)
        let deleted = await service.deletedActivities
        XCTAssertTrue(deleted.contains(where: { $0 == nil }) || deleted.contains("activity-1"))
        let startDeletes = await service.deletedStartTokens
        XCTAssertGreaterThanOrEqual(startDeletes, 1)
    }
}
