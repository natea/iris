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
        self.paired = paired
        if paired == nil {
            runs = []
            stopPolling()
        }
    }

    /// Replaces the list with what a live session's coordinator fetched, so
    /// the two never disagree.
    func adopt(_ list: [LinkTask]) {
        runs = list
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
