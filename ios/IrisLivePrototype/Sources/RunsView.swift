//
//  RunsView.swift
//  IrisLivePrototype
//
//  The run list and the result reader.
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

// MARK: - Views

struct RunsSection: View {
    @ObservedObject var controller: RunsController
    /// The run whose completion Iris is speaking right now, if any.
    var announcingRunId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Hermes runs")
                    .font(.subheadline.weight(.semibold))
                if controller.isLoading { ProgressView().controlSize(.mini) }
                Spacer()
                Button {
                    Task { await controller.refresh(notifying: false) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .font(.caption)
            }

            if controller.notificationsUnavailable {
                Text("Notifications are off, so a run that finishes while the app is closed will show up here on your next visit rather than buzzing.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !controller.message.isEmpty {
                Text(controller.message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.runs.isEmpty {
                Text("No runs yet. Ask Iris to have Hermes do something.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.runs.prefix(12)) { run in
                    RunRow(
                        run: run,
                        isAnnouncing: run.runId == announcingRunId,
                        onOpen: { Task { await controller.read(run.runId) } },
                        onStop: { Task { await controller.stop(run) } }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RunRow: View {
    let run: LinkTask
    let isAnnouncing: Bool
    let onOpen: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(run.status)
                    Text("·")
                    Text(run.origin == "desktop" ? "from the Mac" : "from this phone")
                    if isAnnouncing {
                        Text("· announcing")
                            .foregroundStyle(.blue)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if run.isTerminal {
                Button("Read", action: onOpen).font(.caption2)
            } else {
                Button("Stop", role: .destructive, action: onStop).font(.caption2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if run.isTerminal { onOpen() } }
    }

    private var title: String {
        let line = run.task
            .split(separator: "\n")
            .map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != "Goal:" }
        return line ?? run.task
    }

    private var color: Color {
        switch run.status.lowercased() {
        case "completed": return .green
        case "failed", "error": return .red
        case "cancelled", "canceled": return .orange
        default: return .blue
        }
    }
}

/// The full stored Hermes output. Deliberately raw: no summarizing here, so
/// nothing can be invented between the Mac and the screen.
struct RunResultView: View {
    let sheet: RunsController.RunResultSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(sheet.task)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text(sheet.output)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(sheet.status)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
