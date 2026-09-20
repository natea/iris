//
//  LiveActivityPlan.swift
//  IrisLivePrototype
//
//  The decisions a Live Activity needs, with none of ActivityKit in them: what
//  state describes the runs the phone can see, and whether that means start,
//  update, end or do nothing.
//
//  Separated from the controller so all of it is unit-tested. ActivityKit
//  cannot be driven from a test bundle — there is no simulator API to start a
//  real activity headlessly — so if the rules lived inside the controller they
//  would be checked only by hand on a phone.
//
//  The rules themselves come from LINK_API.md §14:
//
//    · ONE summary activity per device, never one per run (§14.1).
//    · The phone starts an activity only for a run this device dispatched,
//      only while the app is in front, and only when none exists (§14.4).
//    · It ends when the last active run finishes, carrying the REAL terminal
//      status, with a dismissal window of 5 minutes for a clean finish and 30
//      for a bad one — a bad ending is the one you are most likely to have
//      missed (§14.5).
//

import Foundation

enum LiveActivityPlan {

    // MARK: Building the state

    /// The state that describes these runs right now, or nil when there is
    /// nothing active to describe.
    ///
    /// "Primary" is the run a glance should be about: one Hermes is blocked on
    /// first — that is the only thing here a person can act on — then the most
    /// recently updated.
    static func activeState(
        runs: [LinkTask],
        now: Date = Date()
    ) -> IrisRunActivityAttributes.ContentState? {
        let active = runs.filter { !$0.isTerminal }
        guard !active.isEmpty else { return nil }

        let ordered = active.sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
            return IrisEpoch.seconds(lhs.updatedAt) > IrisEpoch.seconds(rhs.updatedAt)
        }
        let primary = ordered[0]
        let approval = primary.pendingApproval

        return .init(
            status: primary.needsAttention ? "waiting" : "running",
            headline: clamp(primary.headline, 80),
            title: clamp(RunTitle.summary(of: primary.task, limit: 80), 80),
            // The list route carries no step preview; §12's per-run detail
            // does, and this activity deliberately does not poll it. Empty is
            // the honest value, and the schema allows it.
            detail: "",
            // `step_count` is what the Mac retained. When it is zero we do not
            // know that nothing happened — only that we have no history — so
            // `stepsKnown` is false and the UI says so instead of "0 steps".
            stepCount: max(0, primary.stepCount),
            stepsKnown: primary.stepCount > 0,
            activeRunCount: active.count,
            needsAttention: approval != nil,
            attentionSummary: clamp(approval?.summary ?? "", 100),
            runs: ordered.prefix(3).map {
                .init(
                    id: $0.runId,
                    title: clamp(RunTitle.summary(of: $0.task, limit: 80), 80),
                    status: $0.needsAttention ? "waiting" : "running",
                    headline: clamp($0.headline, 80)
                )
            },
            startedAt: IrisEpoch.seconds(primary.createdAt),
            updatedAt: now.timeIntervalSince1970
        )
    }

    /// The final state, built from the most recently finished run. The status
    /// word is the desktop's real one, mapped exactly as §14.2 requires:
    /// `failed` never becomes "finished".
    static func endState(
        runs: [LinkTask],
        now: Date = Date()
    ) -> IrisRunActivityAttributes.ContentState {
        let finished = runs
            .filter { $0.isTerminal }
            .max { IrisEpoch.seconds($0.updatedAt) < IrisEpoch.seconds($1.updatedAt) }

        let phase = finished.map { IrisWidgetSnapshot.terminalPhase($0.status) } ?? .idle
        return .init(
            status: phase.rawValue,
            headline: "",
            title: finished.map { clamp(RunTitle.summary(of: $0.task, limit: 80), 80) } ?? "",
            detail: "",
            stepCount: 0,
            stepsKnown: false,
            activeRunCount: 0,
            needsAttention: false,
            attentionSummary: "",
            runs: [],
            startedAt: finished.map { IrisEpoch.seconds($0.createdAt) } ?? 0,
            updatedAt: now.timeIntervalSince1970
        )
    }

    /// §14.5 — `dismissal-date` is +5 minutes for a clean finish and +30 for a
    /// bad one, because a failure is the ending a person is most likely to
    /// have missed. Mirrored here so a locally-ended activity behaves the same
    /// as one the Mac ends by push.
    static func dismissalDelay(for state: IrisRunActivityAttributes.ContentState) -> TimeInterval {
        switch state.phase {
        case .failed, .stopped: return 30 * 60
        default: return 5 * 60
        }
    }

    /// §14.5 — the Mac sets `stale-date` to its push time + 120 s. The app's
    /// own local updates use the same window, so an activity the app stops
    /// being able to refresh goes stale on exactly the same schedule as one
    /// the Mac stops pushing to.
    static let staleWindow: TimeInterval = 120

    // MARK: Deciding

    enum Decision: Equatable {
        case doNothing
        /// Start a new activity with this state.
        case start(IrisRunActivityAttributes.ContentState)
        /// Update the existing one. `alert` is true only on the transition
        /// into "needs you", which is the one moment worth interrupting for.
        case update(IrisRunActivityAttributes.ContentState, alert: Bool)
        /// End the existing one with the real terminal status.
        case end(IrisRunActivityAttributes.ContentState)
    }

    struct Input {
        var runs: [LinkTask] = []
        /// Whether the user has Iris's Live Activity switched on.
        var enabled: Bool = true
        /// `ActivityAuthorizationInfo().areActivitiesEnabled` — iOS's own switch.
        var systemAllows: Bool = true
        /// Whether an activity is already running.
        var hasActivity: Bool = false
        /// Whether `needsAttention` was already true in the live activity.
        var wasNeedingAttention: Bool = false
        /// §14.4: the phone starts locally ONLY while it is in front. From the
        /// background it waits for the Mac's push-to-start instead.
        var appIsActive: Bool = true
        var now: Date = Date()
    }

    static func decide(_ input: Input) -> Decision {
        // Off is off: no start, no update — but an activity that is somehow
        // still running is ended by the caller, not left on the lock screen.
        guard input.enabled, input.systemAllows else {
            return input.hasActivity ? .end(endState(runs: input.runs, now: input.now)) : .doNothing
        }

        guard let state = activeState(runs: input.runs, now: input.now) else {
            // Nothing active. End what exists; never start an activity to say
            // "idle" — a lock screen with nothing on it is the right answer.
            return input.hasActivity ? .end(endState(runs: input.runs, now: input.now)) : .doNothing
        }

        if input.hasActivity {
            return .update(state, alert: state.needsAttention && !input.wasNeedingAttention)
        }

        // §14.4: only a run THIS device dispatched may start an activity, and
        // only from the foreground. A desktop run appears in an activity that
        // already exists; it never conjures one.
        let deviceOrigin = input.runs.contains { !$0.isTerminal && $0.isFromThisPhone }
        guard input.appIsActive, deviceOrigin else { return .doNothing }
        return .start(state)
    }

    // MARK: Helpers

    /// The contract caps these strings; the Mac caps them too, and the phone
    /// caps its own locally-built state so a long title cannot push a local
    /// update out of shape relative to a pushed one.
    private static func clamp(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "…"
    }
}
