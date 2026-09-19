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

    var originLabel: String { isFromThisPhone ? "from this phone" : "from the Mac" }

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
        let seconds = stamp > 100_000_000_000 ? stamp / 1000 : stamp
        return Date(timeIntervalSince1970: seconds)
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

    private var runsStack: some View {
        NavigationStack {
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
                                RunRow(run: run, isAnnouncing: run.runId == announcingRunId) {
                                    Task { await controller.stop(run) }
                                }
                            }
                        }
                    }
                    if !finished.isEmpty {
                        Section("Finished") {
                            ForEach(finished) { run in
                                Button {
                                    Task { await controller.read(run.runId) }
                                } label: {
                                    RunRow(run: run, isAnnouncing: run.runId == announcingRunId, onStop: nil)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
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
        }
    }

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
    /// nil for a finished run, which is tapped to read rather than stopped.
    var onStop: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: run.statusSymbol)
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
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if let onStop {
                Button("Stop", role: .destructive, action: onStop)
                    .font(.caption.weight(.medium))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityLabel("Stop \(run.displayTitle)")
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(run.displayTitle)
        .accessibilityValue(subtitle)
    }

    private var subtitle: String {
        var parts = [run.status.capitalized, run.originLabel]
        if let time = run.relativeTime { parts.append(time) }
        if isAnnouncing { parts.append("Iris is reading this out") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Compact strip for the main screen

/// At most two active runs, so the main screen admits that work is in flight
/// without becoming the run list again.
struct ActiveRunsStrip: View {
    let runs: [LinkTask]
    let onOpen: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var active: [LinkTask] { Array(runs.filter { !$0.isTerminal }.prefix(2)) }

    var body: some View {
        if !active.isEmpty {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(active) { run in
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
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
            .accessibilityLabel("\(active.count) active Hermes run\(active.count == 1 ? "" : "s")")
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
