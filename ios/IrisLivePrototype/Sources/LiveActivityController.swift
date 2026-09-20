//
//  LiveActivityController.swift
//  IrisLivePrototype
//
//  The app's half of the Live Activity (LINK_API.md §14.4, §14.8).
//
//  Everything ActivityKit can do is behind `LiveActivitySource`, for two
//  reasons. The first is testability: a test bundle cannot start a real
//  activity, so the lifecycle rules would otherwise be checked only by hand on
//  a phone. The second is the push-to-start race the contract warns about — an
//  activity the Mac starts while the app is asleep cannot be UPDATED until
//  this phone registers its update token, so adoption has to happen at launch,
//  before any view exists, and that is much easier to get right when the
//  adoption path is a plain object with a delegate.
//
//  What this controller is responsible for, in the order it matters:
//
//    1. Adopt anything already running at launch (push-to-start) and register
//       its update token immediately. Until that PUT lands the Mac is holding
//       an activity it cannot change.
//    2. Register the push-to-start token whenever iOS issues one, so the Mac
//       can raise an activity for a device-origin run while Iris is closed.
//    3. Start locally when this phone dispatches work while it is in front.
//    4. Keep the activity current from the app's own polling, because a push
//       can simply not arrive (§14.5).
//    5. End it — with the REAL terminal status — when the last run finishes.
//    6. Say so when it goes stale, and DELETE the tokens when it is over.
//
//  No token is ever logged or rendered; only `PushDeviceToken.redacted`
//  reaches a string.
//

import Foundation
import SwiftUI

// MARK: - The seam

@MainActor
protocol LiveActivitySourceDelegate: AnyObject {
    /// `activity.pushTokenUpdates` produced a value. §14.8: PUT on EVERY one.
    func liveActivity(didReceiveUpdateToken token: String, activityId: String)
    /// `Activity.pushToStartTokenUpdates` produced a value.
    func liveActivity(didReceiveStartToken token: String)
    /// `.ended` or `.dismissed`.
    func liveActivity(didEnd activityId: String)
    /// `.stale` came or went.
    func liveActivity(didChangeStale isStale: Bool, activityId: String)
    /// An activity that was already running when the app launched.
    func liveActivity(didAdopt activityId: String)
}

/// Everything the controller is allowed to ask of ActivityKit. Deliberately
/// free of ActivityKit types so the fake in the tests is three lines a piece.
@MainActor
protocol LiveActivitySource: AnyObject {
    var delegate: (any LiveActivitySourceDelegate)? { get set }
    /// iOS's own switch (`ActivityAuthorizationInfo().areActivitiesEnabled`).
    /// When this is false the app does nothing and Settings says why.
    var areActivitiesEnabled: Bool { get }
    var runningActivityId: String? { get }

    /// Called as early as possible at launch: adopt activities that are
    /// already running (push-to-start) and start observing token streams.
    func begin()
    func request(
        attributes: IrisRunActivityAttributes,
        state: IrisRunActivityAttributes.ContentState,
        staleDate: Date
    ) throws -> String
    func update(
        id: String,
        state: IrisRunActivityAttributes.ContentState,
        staleDate: Date,
        alert: (title: String, body: String)?
    )
    func end(
        id: String,
        state: IrisRunActivityAttributes.ContentState,
        dismissAfter: TimeInterval
    )
}

// MARK: - Controller

@MainActor
final class LiveActivityController: ObservableObject {

    /// One per app. `IrisAppDelegate` reaches for it at launch — before any
    /// view exists — because adoption cannot wait for a view (§14.8).
    static let shared = LiveActivityController(source: ActivityKitSource())

    /// The user's own switch, persisted. Default ON: a person who paired a
    /// phone to watch Hermes work wants to see it work. Turning it off ends
    /// the activity and DELETEs every token the Mac holds.
    @Published private(set) var isEnabled: Bool
    /// iOS's switch, observed.
    @Published private(set) var systemAllows: Bool = true
    /// The activity currently running, if any.
    @Published private(set) var activityId: String?
    /// Redacted, for Settings. Never the whole token.
    @Published private(set) var tokenSummary: String = ""
    @Published private(set) var startTokenSummary: String = ""
    /// True while iOS reports the activity `.stale` — the Mac stopped
    /// reporting. Settings and the activity itself both say so.
    @Published private(set) var isStale: Bool = false
    /// Plain-language trouble, never a silent failure. `nil` when there is
    /// none — Settings shows this row only when there is something to say.
    @Published private(set) var problem: String?

    static let enabledKey = "iris.liveActivity.enabled"

    private let source: any LiveActivitySource
    /// Test seam. The app always makes a real `LinkClient`; a test puts a
    /// recording double here so the token registrations can be asserted on
    /// without a server. Declared as `any LinkTaskService` so the calls it
    /// makes go through the existential — the same dispatch the app uses, and
    /// the reason those methods are protocol REQUIREMENTS.
    var makeService: (PairedDesktop) -> any LinkTaskService = { LinkClient(paired: $0) }
    private let environment: PushEnvironment
    private var paired: PairedDesktop?
    private var service: (any LinkTaskService)?
    /// §14.5's alert rule: the banner fires on the TRANSITION into "needs
    /// you", not on every update that happens to be waiting.
    private var wasNeedingAttention = false
    private var appIsActive = true
    /// Tokens already sent for this activity, so a repeated identical value
    /// from `pushTokenUpdates` is not a second request.
    private var sentUpdateToken: [String: String] = [:]
    private var sentStartToken: String?

    init(
        source: any LiveActivitySource,
        environment: PushEnvironment = .current,
        defaults: UserDefaults = .standard
    ) {
        self.source = source
        self.environment = environment
        if defaults.object(forKey: Self.enabledKey) == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        }
        self.defaults = defaults
        self.systemAllows = source.areActivitiesEnabled
        source.delegate = self
    }

    private let defaults: UserDefaults

    // MARK: Wiring

    /// Called from the app delegate at launch, before any view exists. The
    /// adoption in here is the fix for the race in §14.8: an activity the Mac
    /// push-started is un-updatable until its token is registered.
    func begin() {
        source.begin()
        systemAllows = source.areActivitiesEnabled
        activityId = source.runningActivityId
    }

    /// Called from `application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// The pairing is read straight from the Keychain rather than waiting for
    /// `PairingController`, because the whole point of being here is to be
    /// early: an activity the Mac push-started is sitting on the lock screen
    /// un-updatable until its token reaches the Mac, and the token arrives
    /// through `pushTokenUpdates` within moments of `begin()`. A controller
    /// that had no service yet at that moment would drop it.
    func bootstrap() {
        configure(paired: KeychainStore.loadPairing())
        begin()
    }

    func configure(paired: PairedDesktop?) {
        let usable = (paired?.credential.isEmpty == false) ? paired : nil
        self.paired = usable
        self.service = usable.map { makeService($0) }
        if usable == nil {
            // Unpairing: end what is on screen. The credential is about to go,
            // so the DELETEs have to happen while it still works — the caller
            // does that through `unpairing()`.
            endNow(reason: .unpaired)
        }
    }

    /// §14.4: the phone may start an activity locally only while it is in
    /// front. From the background it waits for the Mac's push-to-start.
    func setAppActive(_ active: Bool) {
        appIsActive = active
        if active { systemAllows = source.areActivitiesEnabled }
    }

    // MARK: The user's switch

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled {
            endNow(reason: .disabled)
            // §14.7: no query string clears every token this device
            // registered, which is exactly "the user turned it off".
            Task { [service] in
                try? await service?.unregisterLiveActivity(activityId: nil)
                try? await service?.unregisterLiveActivityStartToken()
            }
            sentStartToken = nil
            sentUpdateToken = [:]
            tokenSummary = ""
            startTokenSummary = ""
        }
    }

    /// The credential is about to be deleted; unregister while it still works.
    func unpairing() async {
        endNow(reason: .unpaired)
        try? await service?.unregisterLiveActivity(activityId: nil)
        try? await service?.unregisterLiveActivityStartToken()
        sentStartToken = nil
        sentUpdateToken = [:]
        tokenSummary = ""
        startTokenSummary = ""
    }

    // MARK: The polling hook

    /// Called with every run list the app fetches — the quiet 15 s watch and a
    /// live session's 2 s poll alike. This is what keeps the activity current
    /// when a push is throttled or never arrives (§14.5).
    func observe(runs: [LinkTask], now: Date = Date()) {
        systemAllows = source.areActivitiesEnabled
        let decision = LiveActivityPlan.decide(.init(
            runs: runs,
            enabled: isEnabled,
            systemAllows: systemAllows,
            hasActivity: activityId != nil,
            wasNeedingAttention: wasNeedingAttention,
            appIsActive: appIsActive,
            now: now
        ))
        apply(decision, now: now)
    }

    func apply(_ decision: LiveActivityPlan.Decision, now: Date = Date()) {
        switch decision {
        case .doNothing:
            break

        case .start(let state):
            guard activityId == nil, let paired else { return }
            let attributes = IrisRunActivityAttributes(
                macName: paired.desktopName,
                deviceId: paired.deviceId
            )
            do {
                let id = try source.request(
                    attributes: attributes,
                    state: state,
                    staleDate: now.addingTimeInterval(LiveActivityPlan.staleWindow)
                )
                activityId = id
                wasNeedingAttention = state.needsAttention
                problem = nil
            } catch {
                // Most often: the person has Live Activities off for Iris, or
                // iOS is already showing the maximum. Said plainly rather than
                // retried in a loop.
                problem = "iOS would not start the Live Activity. (\(error.localizedDescription))"
            }

        case .update(let state, let alert):
            guard let id = activityId else { return }
            source.update(
                id: id,
                state: state,
                staleDate: now.addingTimeInterval(LiveActivityPlan.staleWindow),
                alert: alert
                    ? (title: "Hermes needs you",
                       body: state.attentionSummary.isEmpty ? state.shortTitle : state.attentionSummary)
                    : nil
            )
            wasNeedingAttention = state.needsAttention

        case .end(let state):
            guard let id = activityId else { return }
            source.end(id: id, state: state, dismissAfter: LiveActivityPlan.dismissalDelay(for: state))
            finish(activityId: id)
        }
    }

    // MARK: Readout

    /// What Settings prints next to "Live Activity". Every branch is an
    /// observed fact: "Running" without a registered token is precisely the
    /// state that looks like it works and can never be updated, so the two are
    /// never collapsed into one word.
    var stateLabel: String {
        guard systemAllows else { return "Turned off in iOS Settings" }
        guard isEnabled else { return "Off" }
        guard activityId != nil else { return "Not running" }
        if isStale { return "Running · your Mac stopped reporting" }
        return tokenSummary.isEmpty ? "Running · waiting for its push token" : "Running · your Mac can update it"
    }

    private enum EndReason { case disabled, unpaired }

    private func endNow(reason: EndReason) {
        guard let id = activityId else { return }
        let state = IrisRunActivityAttributes.ContentState(
            status: "idle",
            headline: "",
            title: "",
            activeRunCount: 0,
            updatedAt: Date().timeIntervalSince1970
        )
        // Immediately, not after five minutes: the person just asked for this
        // to be off their lock screen.
        source.end(id: id, state: state, dismissAfter: 0)
        finish(activityId: id)
    }

    private func finish(activityId id: String) {
        activityId = nil
        wasNeedingAttention = false
        isStale = false
        tokenSummary = ""
        sentUpdateToken.removeValue(forKey: id)
        Task { [service] in try? await service?.unregisterLiveActivity(activityId: id) }
    }
}

// MARK: - Token registration

extension LiveActivityController: LiveActivitySourceDelegate {

    func liveActivity(didReceiveUpdateToken token: String, activityId id: String) {
        guard isEnabled else { return }
        // A repeat of the same value is not news; a CHANGED one is, and the
        // old one is dead the moment it changes.
        guard sentUpdateToken[id] != token else { return }
        sentUpdateToken[id] = token
        tokenSummary = PushDeviceToken.redacted(token)
        if activityId == nil { activityId = id }
        Task { [service, environment] in
            do {
                _ = try await service?.registerLiveActivityToken(
                    activityId: id, token: token, environment: environment)
                await MainActor.run { self.problem = nil }
            } catch let error as LinkError {
                await MainActor.run {
                    self.sentUpdateToken[id] = nil
                    self.problem = "Your Mac did not accept this Live Activity. (\(error.message))"
                }
            } catch {
                await MainActor.run { self.sentUpdateToken[id] = nil }
            }
        }
    }

    func liveActivity(didReceiveStartToken token: String) {
        guard isEnabled else { return }
        guard sentStartToken != token else { return }
        sentStartToken = token
        startTokenSummary = PushDeviceToken.redacted(token)
        Task { [service, environment] in
            do {
                _ = try await service?.registerLiveActivityStartToken(token, environment: environment)
            } catch {
                await MainActor.run { self.sentStartToken = nil }
            }
        }
    }

    func liveActivity(didEnd id: String) {
        guard activityId == id || activityId == nil else { return }
        finish(activityId: id)
    }

    func liveActivity(didChangeStale stale: Bool, activityId id: String) {
        guard id == activityId else { return }
        isStale = stale
    }

    func liveActivity(didAdopt id: String) {
        // Push-to-start: the Mac raised this while Iris was closed. Its update
        // token arrives through `pushTokenUpdates` a moment later and is
        // registered above; until then the Mac cannot change what is on the
        // lock screen.
        activityId = id
    }
}
