//
//  RunsView.swift
//  IrisLivePrototype
//
//  The run list's controller. The views that draw it live in RunsScreen.swift.
//
//  The list is `GET /link/tasks` for the pinned Hermes session, so it shows
//  runs dispatched from the Mac as well as from this phone — the mobile spec
//  requires both. A finished run can be opened and read; an active one can be
//  stopped.
//
//  While no Live session is running, this is also what watches for
//  completions and asks RunNotifier to raise a local notification. See the
//  honesty note at the top of RunNotifier.swift about what iOS actually
//  permits without push.
//

import SwiftUI

@MainActor
final class RunsController: ObservableObject {

    @Published private(set) var runs: [LinkTask] = []
    @Published var isLoading = false
    @Published var message = ""
    @Published var openResult: RunResultSheet?
    @Published var isReadingResult = false

    /// Set when a completion could not be notified, so the UI can say that
    /// plainly instead of implying the user was told.
    @Published var notificationsUnavailable = false

    /// A run a tapped notification asked for. The Runs screen pushes its
    /// detail and clears this.
    @Published var pendingOpen: LinkTask?
    /// The pending request id a `needs_attention` tap arrived with, so the
    /// detail screen can surface that approval rather than a stale one.
    @Published var pendingOpenRequestId: String?

    let notifier = RunNotifier()

    private var paired: PairedDesktop?
    private var poller: Task<Void, Never>?
    var onLinkError: ((LinkError) -> Void)?

    struct RunResultSheet: Identifiable {
        let id: String
        let task: String
        let status: String
        let output: String
    }

    func configure(paired: PairedDesktop?) {
        // A record with no credential cannot ask the Mac anything — every
        // call would come back `not_paired` and clear the pairing. That is
        // what a DEBUG screenshot fixture looks like, and treating it as
        // unpaired here is simpler and safer than special-casing fixtures.
        let usable = (paired?.credential.isEmpty == false) ? paired : nil
        self.paired = usable
        if usable == nil {
            runs = []
            stopPolling()
        }
    }

    /// Replaces the list with what a live session's coordinator fetched, so
    /// the two never disagree.
    func adopt(_ list: [LinkTask]) {
        runs = list
    }

    // MARK: Earlier chats (LINK_API.md §16.4)
    //
    // When the pinned Hermes chat changes, every run under the previous one
    // vanishes from both apps. They are still real work the user did, so they
    // get their own collapsed group — loaded ON DEMAND, because a chat's worth
    // of history is not something a 5 s list poll should be dragging around.
    //
    // They are read-only and they are history: they must never reach the
    // notifier, the announcement queue, the active-runs strip or a Live
    // Activity. `runs` is deliberately left untouched.

    @Published private(set) var earlier: [LinkTask] = []
    @Published private(set) var isLoadingEarlier = false
    /// Nil until asked for. `false` means the Mac is older than §16.4 and
    /// cannot answer — which is not the same as "there are none".
    @Published private(set) var earlierAvailable: Bool?

    func loadEarlier() async {
        guard let client, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        do {
            let list = try await client.listAllTasks()
            earlier = list.earlier
            earlierAvailable = true
        } catch let error as LinkError {
            earlierAvailable = false
            message = error.message
            if error.clearsPairing { onLinkError?(error) }
        } catch {
            earlierAvailable = false
            message = "Could not read the earlier chats."
        }
    }

    private var client: LinkClient? {
        guard let paired else { return nil }
        return LinkClient(paired: paired)
    }

    /// The service a pushed run-detail screen polls with. A fresh client per
    /// screen, so its 2 s loop cannot disturb the list's own.
    var taskClient: LinkTaskService? { client }

    func refresh(notifying: Bool) async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await client.listTasks(undelivered: false)
            runs = list
            message = ""
            if notifying {
                await notifier.refreshPermission()
                let delivered = await notifier.notifyIfNeeded(list)
                let pending = list.contains { $0.isTerminal && $0.isFromThisPhone }
                // Never claim a notification that did not happen.
                notificationsUnavailable = pending && delivered.isEmpty
                    && notifier.permission != .granted
            }
        } catch let error as LinkError {
            message = error.message
            if error.clearsPairing { onLinkError?(error) }
        } catch {
            message = "Could not list Hermes runs."
        }
    }

    // MARK: Answering an approval from the main screen
    //
    // SECURITY INVARIANT: `answerApproval` is called from the main screen's
    // Approve / Deny button closures and from nowhere else. The exactly-once,
    // staleness and `409` rules all live in `ApprovalAnswerer`, shared with
    // the run-detail screen so the two cannot drift.

    let approvals = ApprovalAnswerer()
    /// Which decision is in flight, for the progress on the pressed button.
    @Published private(set) var sendingApproval: ApprovalDecision?
    /// The plain-language result of the last answer given from the main
    /// screen. Never a claim that something landed when it did not.
    @Published var approvalMessage = ""

    /// The one thing on the main screen worth interrupting for: a run of this
    /// device's that Hermes is blocked on, and that this phone can answer.
    var approvableRun: LinkTask? {
        runs.first {
            !$0.isTerminal && ($0.pendingApproval?.canApproveFromPhone ?? false)
        }
    }

    func answerApproval(_ decision: ApprovalDecision, approval: PendingApproval, runId: String) async {
        guard sendingApproval == nil else { return }
        sendingApproval = decision
        defer { sendingApproval = nil }
        // The live list is the only honest answer to "what is it waiting on
        // NOW"; a tap for anything else is refused rather than redirected.
        let current = runs.first { $0.runId == runId }?.pendingApproval?.requestId
        let outcome = await approvals.answer(
            decision, approval: approval, runId: runId,
            currentRequestId: current, service: taskClient
        )
        approvalMessage = outcome.message
        switch outcome {
        case .answered, .alreadyAnswered: Haptics.success()
        default: Haptics.error()
        }
        await refresh(notifying: false)
    }

    func stop(_ run: LinkTask) async {
        guard let client else { return }
        do {
            _ = try await client.stopTask(runId: run.runId)
            message = "Asked Hermes to stop that run."
            await refresh(notifying: false)
        } catch let error as LinkError {
            message = error.message
        } catch {
            message = "Could not stop that run."
        }
    }

    func read(_ runId: String) async {
        guard let client else { return }
        isReadingResult = true
        defer { isReadingResult = false }
        do {
            let result = try await client.taskResult(runId: runId)
            openResult = .init(
                id: result.runId,
                task: result.task,
                status: result.status,
                output: result.output.isEmpty ? "(Hermes returned no text output.)" : result.output
            )
            notifier.markHandled(runId)
        } catch LinkError.taskNotFinished {
            message = "That run has not finished yet."
        } catch let error as LinkError {
            message = error.message
        } catch {
            message = "Could not read that result."
        }
    }

    /// A tapped notification (local or push) names a run. Open THAT run's
    /// detail screen — never a summary, and never a result read out of the
    /// notification, which does not contain one (§11.3).
    ///
    /// The run is usually already in the list. When it is not — a push that
    /// arrived while the app was asleep, opened from a cold launch — the
    /// status route supplies a seed. If even that fails, nothing is opened and
    /// the reason is shown; a blank screen with a run id on it would be worse.
    func open(notice: PushNotice) async {
        pendingOpenRequestId = notice.requestId.isEmpty ? nil : notice.requestId
        if let known = runs.first(where: { $0.runId == notice.runId }) {
            pendingOpen = known
            return
        }
        guard let client else { return }
        do {
            let status = try await client.taskStatus(runId: notice.runId)
            pendingOpen = LinkTask(
                runId: status.runId,
                task: status.task,
                status: status.status,
                origin: status.origin.isEmpty ? "device:" : status.origin,
                pendingApproval: status.pendingApproval
            )
            await refresh(notifying: false)
        } catch let error as LinkError {
            message = error.message
            if error.clearsPairing { onLinkError?(error) }
        } catch {
            message = "Could not open that run."
        }
    }

    /// A deep link from the Live Activity or the home-screen widget
    /// (`iris://run/<id>`, §14.8). The id came from a payload this phone did
    /// not author, so it is validated before it is used and an id that does
    /// not look like a run id opens nothing at all.
    func openFromDeepLink(runId: String) async {
        guard IrisRunLink.isValidRunId(runId) else { return }
        pendingOpenRequestId = nil
        if let known = runs.first(where: { $0.runId == runId }) {
            pendingOpen = known
            return
        }
        guard let client else { return }
        do {
            let status = try await client.taskStatus(runId: runId)
            pendingOpen = LinkTask(
                runId: status.runId,
                task: status.task,
                status: status.status,
                origin: status.origin.isEmpty ? "device:" : status.origin,
                pendingApproval: status.pendingApproval
            )
            await refresh(notifying: false)
        } catch let error as LinkError {
            message = error.message
            if error.clearsPairing { onLinkError?(error) }
        } catch {
            message = "Could not open that run."
        }
    }

    /// Runs only while no Live session is active. A session of its own polls
    /// on the contract's 2 s cadence; this is the quieter background watch.
    func startPolling() {
        guard poller == nil, paired != nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(notifying: true)
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    func stopPolling() {
        poller?.cancel()
        poller = nil
    }
}
