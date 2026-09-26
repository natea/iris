//
//  RunsScreen.swift
//  IrisLivePrototype
//
//  The run list, off the main screen and on its own. Grouped Active /
//  Finished, because "is anything happening right now" is the only question
//  this screen is ever opened to answer.
//
//  State is carried by an icon *and* a colour, never colour alone.
//

import SwiftUI

// MARK: - Run presentation

extension LinkTask {

    /// First meaningful line of the brief — the list is a list of intents, not
    /// of prompts.
    var displayTitle: String {
        let line = task
            .split(separator: "\n")
            .map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != "Goal:" }
        let text = (line ?? task).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "Untitled run" : text
    }

    /// Where it came from. A restored run says so subtly rather than claiming
    /// a phone or a Mac dispatched it — nothing here did (§16.2).
    var originLabel: String {
        if isHistory { return "from the chat history" }
        return isFromThisPhone ? "from this phone" : "from the Mac"
    }

    var statusSymbol: String {
        switch status.lowercased() {
        case "completed": return "checkmark.circle.fill"
        case "failed", "error": return "exclamationmark.triangle.fill"
        case "cancelled", "canceled": return "xmark.circle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    var statusColor: Color {
        switch status.lowercased() {
        case "completed": return .green
        case "failed", "error": return .red
        case "cancelled", "canceled": return .orange
        default: return .blue
        }
    }

    /// "2 minutes ago", or nil when the desktop sent no timestamp.
    var relativeTime: String? {
        let stamp = updatedAt > 0 ? updatedAt : createdAt
        guard stamp > 0 else { return nil }
        // The desktop reports JavaScript timestamps (milliseconds); read as
        // seconds they land tens of thousands of years in the future.
        return Date(timeIntervalSince1970: IrisEpoch.seconds(stamp))
            .formatted(.relative(presentation: .named))
    }
}

// MARK: - Screen

struct RunsScreen: View {
    @ObservedObject var controller: RunsController
    var announcingRunId: String?
    /// DEBUG launch-argument fixtures; nil in every production path.
    var injectedRuns: [LinkTask]?

    @Environment(\.dismiss) private var dismiss

    private var runs: [LinkTask] { injectedRuns ?? controller.runs }
    private var active: [LinkTask] { runs.filter { !$0.isTerminal } }
    private var finished: [LinkTask] { runs.filter(\.isTerminal) }

    var body: some View {
        runsStack
            // Presented from here, not from the root: a view that is already
            // showing the Runs sheet cannot present a second one, so the result
            // used to appear only after Runs was dismissed.
            .sheet(item: $controller.openResult) { result in
                RunResultView(sheet: result)
            }
    }

    @State private var path: [LinkTask] = []
    @State private var earlierExpanded = false

    private var runsStack: some View {
        NavigationStack(path: $path) {
            List {
                if controller.notificationsUnavailable {
                    noticeRow(
                        "Notifications are off, so a run that finishes while the app is closed will be waiting here rather than buzzing.",
                        symbol: "bell.slash"
                    )
                }
                if !controller.message.isEmpty {
                    noticeRow(controller.message, symbol: "exclamationmark.circle")
                }

                if runs.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No runs yet",
                            systemImage: "tray",
                            description: Text("Ask Iris to have Hermes do something, and it will show up here.")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    if !active.isEmpty {
                        Section("Active") {
                            ForEach(active) { run in
                                NavigationLink(value: run) {
                                    RunRow(run: run, isAnnouncing: run.runId == announcingRunId)
                                }
                                // Stop moved to a swipe and to the detail
                                // screen's toolbar: a row that pushes cannot
                                // also carry a button the touch has to miss.
                                .swipeActions(edge: .trailing) {
                                    Button("Stop", role: .destructive) {
                                        Task { await controller.stop(run) }
                                    }
                                }
                            }
                        }
                    }
                    if !finished.isEmpty {
                        Section("Finished") {
                            ForEach(finished) { run in
                                NavigationLink(value: run) {
                                    RunRow(run: run, isAnnouncing: run.runId == announcingRunId)
                                }
                            }
                        }
                    }
                }
                earlierSection
            }
            .listStyle(.insetGrouped)
            // Pushed, not presented: this sheet is already a presentation, and
            // a view that is presenting one cannot present a second.
            .navigationDestination(for: LinkTask.self) { run in
                detail(for: run)
            }
            .refreshable { await controller.refresh(notifying: false) }
            .navigationTitle("Runs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if controller.isReadingResult { ProgressView().controlSize(.large) }
            }
            .onChange(of: controller.pendingOpen) { _, run in
                // A tapped notification lands here: push that run's detail,
                // replacing whatever was on the stack.
                guard let run else { return }
                controller.pendingOpen = nil
                path = [run]
            }
            .onAppear {
                if let run = controller.pendingOpen {
                    controller.pendingOpen = nil
                    path = [run]
                }
                #if DEBUG
                // `-uiPreviewRun <runId>` opens straight onto a run's progress
                // so it can be screenshotted without tapping. DEBUG only, and
                // only when fixtures were already injected.
                if injectedRuns != nil, path.isEmpty,
                   let id = RunsScreen.previewRunFromLaunchArguments(),
                   let run = runs.first(where: { $0.runId == id }) {
                    path = [run]
                }
                #endif
            }
        }
    }

    /// Runs from chats that are no longer pinned (LINK_API.md §16.4).
    /// Collapsed by default with a count, loaded on demand, and kept out of
    /// Active / Finished entirely — they are history, not news.
    @ViewBuilder
    private var earlierSection: some View {
        if injectedRuns == nil {
            Section {
                DisclosureGroup(isExpanded: $earlierExpanded) {
                    if controller.isLoadingEarlier {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading earlier chats…").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if controller.earlierAvailable == false {
                        Text("Iris on your Mac is too old to list earlier chats. Update it there.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if controller.earlier.isEmpty {
                        Text("Nothing from an earlier chat.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.earlier) { run in
                            NavigationLink(value: run) {
                                RunRow(run: run, isAnnouncing: false)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Earlier chats")
                        if !controller.earlier.isEmpty {
                            Text("\(controller.earlier.count)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("earlier-chats")
                .onChange(of: earlierExpanded) { _, expanded in
                    // On demand: a chat's worth of history is not something a
                    // 5 s poll should be dragging around.
                    guard expanded, controller.earlierAvailable == nil else { return }
                    Task { await controller.loadEarlier() }
                }
            } footer: {
                Text("Work from Hermes chats that are no longer pinned. Read-only.")
            }
        }
    }

    @ViewBuilder
    private func detail(for run: LinkTask) -> some View {
        #if DEBUG
        if injectedRuns != nil, let canned = RunProgressFixtures.detail(for: run.runId) {
            RunDetailView(run: run, detail: canned, result: RunProgressFixtures.result(for: run.runId))
        } else {
            RunDetailView(run: run, service: controller.taskClient,
                          highlightRequestId: controller.pendingOpenRequestId,
                          onAnswered: controller.approvals.onAnswered)
        }
        #else
        RunDetailView(run: run, service: controller.taskClient,
                      highlightRequestId: controller.pendingOpenRequestId,
                      onAnswered: controller.approvals.onAnswered)
        #endif
    }

    #if DEBUG
    static func previewRunFromLaunchArguments() -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-uiPreviewRun"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    #endif

    private func noticeRow(_ text: String, symbol: String) -> some View {
        Label {
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .foregroundStyle(.orange)
        .listRowBackground(Color.clear)
    }
}

// MARK: - Row

struct RunRow: View {
    let run: LinkTask
    let isAnnouncing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RunStatusIcon(symbol: run.statusSymbol, isActive: !run.isTerminal)
                .foregroundStyle(run.statusColor)
                .font(.body)
                .frame(width: 22)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(run.displayTitle)
                    .font(.subheadline)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                // §11.5: a run Hermes is waiting on says so here, in the list,
                // so it is not something only a notification could tell you.
                if run.needsAttention {
                    Label("Hermes is waiting for you", systemImage: "hand.raised.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                // §15.2: a failed row says WHY, here, in the list. "FAILED"
                // with no reason is the thing this replaces.
                if let reason = failureLine {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("run-row-failure")
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The live line, straight from the desktop's own wording. Only
                // for an active run, and only when there is something real to
                // say — an empty headline is never filled in with a guess.
                if let live = liveLine {
                    Text(live)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(run.displayTitle)
        .accessibilityValue(
            ([run.needsAttention ? "Hermes is waiting for you" : nil, failureLine, subtitle, liveLine])
                .compactMap { $0 }.joined(separator: " · ")
        )
    }

    /// The Mac's own sentence for a failed run, or nil. Never a sentence this
    /// app invented, and never the generic "not reachable" line.
    private var failureLine: String? {
        guard let failure = run.failure, !failure.message.isEmpty else { return nil }
        return failure.message
    }

    private var subtitle: String {
        var parts = [run.status.capitalized, run.originLabel]
        if let time = run.relativeTime { parts.append(time) }
        if isAnnouncing { parts.append("Iris is reading this out") }
        // NOT "waiting for you" again: the orange label above already says it,
        // and the desktop's headline usually says it a third time.
        return parts.joined(separator: " · ")
    }

    /// "Running code · 3 steps" — §12.1's two list fields and nothing more.
    private var liveLine: String? {
        guard !run.isTerminal else { return nil }
        var parts: [String] = []
        if !run.headline.isEmpty { parts.append(run.headline) }
        if run.stepCount > 0 { parts.append("\(run.stepCount) step\(run.stepCount == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Compact strip for the main screen

/// At most two active runs, so the main screen admits that work is in flight
/// without becoming the run list again.
struct ActiveRunsStrip: View {
    let runs: [LinkTask]
    let onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // History is never "in flight": a restored run finished long ago.
    private var active: [LinkTask] {
        Array(runs.filter { !$0.isTerminal && !$0.isHistory }.prefix(2))
    }

    var body: some View {
        if !active.isEmpty {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(active) { run in
                        HStack(spacing: 8) {
                            if run.needsAttention {
                                Image(systemName: "hand.raised.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                            Text(run.displayTitle)
                                .font(.caption)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            // At accessibility sizes the title matters more
                            // than where the run came from.
                            if !dynamicTypeSize.isAccessibilitySize {
                                Text(run.originLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .irisGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                active.contains(where: \.needsAttention)
                    ? "\(active.count) active Hermes run\(active.count == 1 ? "" : "s"), one is waiting for you"
                    : "\(active.count) active Hermes run\(active.count == 1 ? "" : "s")"
            )
            .accessibilityHint("Opens the run list")
        }
    }
}

// MARK: - Reader

/// The full stored Hermes output. Deliberately raw: no summarizing here, so
/// nothing can be invented between the Mac and the screen.
struct RunResultView: View {
    let sheet: RunsController.RunResultSheet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(sheet.task)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    MarkdownText(source: sheet.output)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(sheet.status.capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: sheet.output) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share this result")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
