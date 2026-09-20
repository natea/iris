//
//  RunDetailView.swift
//  IrisLivePrototype
//
//  What Hermes is doing right now, not just what it finally said — the
//  desktop's WorkCard, pushed inside the Runs sheet's existing NavigationStack
//  (a view already presenting a sheet cannot present a second one).
//
//  This screen is content, not control, so it uses the standard grouped list
//  surfaces rather than glass. Glass stays on the control layer.
//
//  Two rules it never bends, both from LINK_API.md §12:
//    · no events → no steps, and the screen says so in plain words;
//    · no percentage. Hermes reports none, so the bar is indeterminate.
//
//  It is also where a pending approval is answered (§11.5). That path is
//  deliberately different from the spoken one: the dispatch gate in §6 exists
//  because a model can mishear a person, and nothing here goes through it,
//  because nothing here is heard. An approval is sent only when a finger taps
//  Approve or Deny and then confirms a dialog that restates the command
//  verbatim. There is no code path from a tool call, a transcript, a push, or
//  any other model output to `resolve(_:)` — the model cannot reach this
//  screen's buttons, and the buttons are the only caller.
//

import SwiftUI

// MARK: - Controller

@MainActor
final class RunDetailController: ObservableObject {

    @Published private(set) var progress = RunProgressStore()
    @Published private(set) var status: LinkTaskStatus?
    @Published private(set) var result: String?
    @Published private(set) var isStopping = false
    @Published var message = ""
    /// Set while an approval is being sent, so the buttons cannot be tapped
    /// twice into two decisions.
    @Published private(set) var isResolving = false
    /// What the last approval did, in plain words. Never a claim that a
    /// decision landed when it did not.
    @Published var approvalOutcome = ""

    /// The list entry the screen opened from, so there is something honest to
    /// draw before the first poll returns.
    let seed: LinkTask
    private let service: LinkTaskService?

    init(seed: LinkTask, service: LinkTaskService?) {
        self.seed = seed
        self.service = service
    }

    var runId: String { seed.runId }

    var currentStatus: String {
        let live = status?.status ?? ""
        return live.isEmpty ? seed.status : live
    }

    var isActive: Bool { !LinkRunStatus.isTerminal(currentStatus) }

    /// §11.5 — live state only. The seed's copy is used until the first poll
    /// returns so the card does not flash in a moment after a push.
    var pendingApproval: PendingApproval? {
        status?.pendingApproval ?? (status == nil ? seed.pendingApproval : nil)
    }

    /// §12: an empty headline is not filled in with a guess.
    var headline: String {
        progress.headline.isEmpty ? currentStatus.capitalized : progress.headline
    }

    var brief: String {
        let live = status?.task ?? ""
        return live.isEmpty ? seed.task : live
    }

    /// `GET /link/tasks/:id?steps_since=…` every 2 s while the screen is up
    /// and the run is active (§12.6). One request, not two: this is the same
    /// call that carries status.
    ///
    /// Started from `.task(id:)`, so SwiftUI cancels it when the screen
    /// disappears. It also returns of its own accord once the run is terminal.
    func poll() async {
        var backoff: UInt64 = 1
        while !Task.isCancelled {
            let ok = await fetchOnce()
            if ok {
                backoff = 1
                if !isActive {
                    // Terminal: one last fetch has happened, so take the
                    // result once and stop looking.
                    await fetchResult()
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            } else {
                if case .notPaired? = lastFatal { return }
                if case .taskUnknown? = lastFatal { return }
                // §9: 1 s, 2 s, 4 s … capped at 30 s. A failed poll is not a
                // step that failed; keep what we hold.
                progress.requireFullResync()
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
            }
        }
    }

    private var lastFatal: LinkError?

    @discardableResult
    func fetchOnce() async -> Bool {
        guard let service else { return false }
        do {
            let detail = try await service.taskStatus(runId: runId, stepsSince: progress.nextStepsSince)
            status = detail.task
            progress.apply(detail)
            if let output = detail.task.output, !output.isEmpty { result = output }
            message = ""
            lastFatal = nil
            return true
        } catch let error as LinkError {
            lastFatal = error
            message = error.message
            return false
        } catch {
            message = "Could not reach Iris on your Mac."
            return false
        }
    }

    /// On return from the background, resynchronize with one full fetch
    /// (§12.6) rather than trusting a cursor we may have slept through.
    func resynchronize() {
        progress.requireFullResync()
    }

    private func fetchResult() async {
        guard let service, result == nil else { return }
        do {
            let stored = try await service.taskResult(runId: runId)
            result = stored.output.isEmpty ? "(Hermes returned no text output.)" : stored.output
        } catch LinkError.taskNotFinished {
            // Raced the status; the next visit will pick it up.
        } catch let error as LinkError {
            message = error.message
        } catch {
            message = "Could not read that result."
        }
    }

    /// The ONLY caller is the confirmed Approve/Deny button in this screen.
    /// §4: this route resolves the approval exactly as the desktop's own
    /// buttons do, so the human gate is the phone's responsibility — here it
    /// is a deliberate tap plus a confirmation that restates the command.
    func resolve(_ decision: ApprovalDecision) async {
        guard let service, !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            try await service.resolveApproval(runId: runId, decision: decision.rawValue)
            approvalOutcome = decision.isDenial
                ? "Denied. Hermes has been told no."
                : "Approved (\(decision.rawValue)). Hermes is carrying on."
            message = ""
            await fetchOnce()
        } catch LinkError.approvalNotPending {
            approvalOutcome = ""
            message = "Hermes has no pending approval for this run any more — it was already answered on the Mac, or it timed out."
            await fetchOnce()
        } catch let error as LinkError {
            approvalOutcome = ""
            message = error.message
        } catch {
            approvalOutcome = ""
            message = "Could not send that decision to Hermes."
        }
    }

    func stop() async {
        guard let service else { return }
        isStopping = true
        defer { isStopping = false }
        do {
            _ = try await service.stopTask(runId: runId)
            message = "Asked Hermes to stop this run."
            await fetchOnce()
        } catch let error as LinkError {
            message = error.message
        } catch {
            message = "Could not stop that run."
        }
    }

    // MARK: DEBUG fixtures

    #if DEBUG
    /// Fills the screen from a canned detail without any client. Only ever
    /// called from a `#Preview` or from a launch-argument fixture, both of
    /// which are compiled out of a release build.
    func _previewSeed(_ detail: LinkTaskDetail, result: String? = nil) {
        status = detail.task
        progress.apply(detail)
        self.result = result
    }
    #endif
}

// MARK: - Screen

struct RunDetailView: View {

    @StateObject private var controller: RunDetailController
    @Environment(\.scenePhase) private var scenePhase

    @State private var briefExpanded = false
    @State private var expandedStepIds: Set<String> = []
    @State private var stepsExpanded = true
    @State private var isAtBottom = true
    @State private var confirmStop = false
    /// The approval awaiting a second, explicit confirmation. Nothing is sent
    /// while these are nil, and only a tap can set them.
    @State private var confirmApproval: PendingApproval?
    @State private var confirmDenial: PendingApproval?

    /// nil in every production path; set only by a DEBUG fixture.
    private let injected: LinkTaskDetail?
    private let injectedResult: String?

    /// `highlightRequestId` is the request a `needs_attention` push named. It
    /// is used only to confirm the card on screen is the one the notification
    /// was about; a mismatch is reported rather than silently answered.
    init(run: LinkTask, service: LinkTaskService?, highlightRequestId: String? = nil) {
        _controller = StateObject(wrappedValue: RunDetailController(seed: run, service: service))
        injected = nil
        injectedResult = nil
        self.highlightRequestId = highlightRequestId
    }

    private let highlightRequestId: String?

    #if DEBUG
    init(run: LinkTask, detail: LinkTaskDetail, result: String? = nil) {
        _controller = StateObject(wrappedValue: RunDetailController(seed: run, service: nil))
        injected = detail
        injectedResult = result
        self.highlightRequestId = nil
    }
    #endif

    var body: some View {
        ScrollViewReader { proxy in
            List {
                headerSection
                approvalSection
                briefSection
                if controller.isActive { liveSection }
                stepsSection
                noticeSection
                resultSection
                runIdFooter
            }
            .listStyle(.insetGrouped)
            .onChange(of: controller.progress.steps.last?.id) { previous, newest in
                // Never on the first load: the screen opens at the top, on the
                // status and the task, not halfway down a step list.
                guard previous != nil else { return }
                // After that, only follow the newest step when the reader is
                // already at the bottom. Yanking the scroll out from under
                // someone reading an earlier step is worse than a stale view.
                guard isAtBottom, let newest else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(newest, anchor: .bottom) }
            }
        }
        // A person recognizes the task, not the id; the id is kept, small, at
        // the bottom for debugging.
        .navigationTitle(RunTitle.summary(of: controller.seed.task))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task(id: controller.runId) {
            if injected == nil { await controller.poll() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.resynchronize() }
        }
        .onAppear {
            #if DEBUG
            if let injected { controller._previewSeed(injected, result: injectedResult) }
            #endif
        }
        .confirmationDialog(
            "Stop this run?",
            isPresented: $confirmStop,
            titleVisibility: .visible
        ) {
            Button("Stop the run", role: .destructive) {
                Task { await controller.stop() }
            }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Hermes will stop where it is. Anything it has already done stays done.")
        }
        // Two taps, and the command is restated in full on the second one: the
        // whole point of the gate is that nobody approves something they have
        // not just read.
        .confirmationDialog(
            "Let Hermes do this?",
            isPresented: Binding(get: { confirmApproval != nil }, set: { if !$0 { confirmApproval = nil } }),
            titleVisibility: .visible,
            presenting: confirmApproval
        ) { approval in
            ForEach(ApprovalDecision.allCases.filter { !$0.isDenial }, id: \.rawValue) { decision in
                Button(decision.buttonTitle) {
                    confirmApproval = nil
                    Task { await controller.resolve(decision) }
                }
            }
            Button("Cancel", role: .cancel) { confirmApproval = nil }
        } message: { approval in
            Text(approval.summary)
        }
        .confirmationDialog(
            "Deny this?",
            isPresented: Binding(get: { confirmDenial != nil }, set: { if !$0 { confirmDenial = nil } }),
            titleVisibility: .visible,
            presenting: confirmDenial
        ) { _ in
            Button("Deny", role: .destructive) {
                confirmDenial = nil
                Task { await controller.resolve(.deny) }
            }
            Button("Cancel", role: .cancel) { confirmDenial = nil }
        } message: { approval in
            Text(approval.summary)
        }
    }

    // MARK: Approval (LINK_API.md §11.5)

    @ViewBuilder
    private var approvalSection: some View {
        if let approval = controller.pendingApproval {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Hermes is waiting for you", systemImage: "hand.raised.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)

                    // Hermes' own words, shown and never followed.
                    Text(approval.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if approval.canApproveFromPhone {
                        Text("Answering here does exactly what the buttons in Iris on your Mac do.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button("Approve…") { confirmApproval = approval }
                                .buttonStyle(.borderedProminent)
                            Button("Deny…", role: .destructive) { confirmDenial = approval }
                                .buttonStyle(.bordered)
                            if controller.isResolving { ProgressView().controlSize(.mini) }
                        }
                        .disabled(controller.isResolving)
                        .padding(.top, 2)
                    } else {
                        // §4: clarifications, sudo and secrets travel over
                        // Hermes' interactive socket, which Link does not
                        // carry. There is no route, so there is no button.
                        Label(
                            "This one has to be answered in Iris on your Mac. Iris Link cannot carry it.",
                            systemImage: "desktopcomputer"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if let mismatch = requestMismatchNotice(approval) {
                        Text(mismatch)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Hermes is waiting for you. \(approval.summary)")
            }
        } else if !controller.approvalOutcome.isEmpty {
            Section {
                Label(controller.approvalOutcome, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The notification named one request; the run is now waiting on another.
    /// Say so rather than let a tap answer something it was not about.
    private func requestMismatchNotice(_ approval: PendingApproval) -> String? {
        guard let highlightRequestId, !highlightRequestId.isEmpty,
              highlightRequestId != approval.requestId else { return nil }
        return "The notification you tapped was about an earlier question. This is what Hermes is waiting on now."
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    statusChip
                    Spacer(minLength: 0)
                    if controller.isStopping { ProgressView().controlSize(.mini) }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(controller.currentStatus.capitalized). \(subtitle)")

            if !controller.message.isEmpty {
                Label {
                    Text(controller.message)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .foregroundStyle(.orange)
            }
        }
    }

    private var statusChip: some View {
        HStack(spacing: 5) {
            RunStatusIcon(symbol: seedForChip.statusSymbol, isActive: controller.isActive)
                .font(.caption2.weight(.bold))
            Text(controller.currentStatus.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(seedForChip.statusColor)
        .background(seedForChip.statusColor.opacity(0.15), in: Capsule())
        .accessibilityHidden(true)
    }

    /// A LinkTask carrying the *live* status, so the chip's symbol and colour
    /// track the poll rather than the row that was tapped.
    private var seedForChip: LinkTask {
        LinkTask(
            runId: controller.runId, task: controller.brief,
            status: controller.currentStatus, origin: controller.seed.origin
        )
    }

    private var subtitle: String {
        var parts = [controller.seed.originLabel]
        if let time = controller.seed.relativeTime { parts.append(time) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var briefSection: some View {
        let brief = controller.brief
        if !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Section("Task") {
                if briefExpanded || !briefIsLong {
                    MarkdownText(source: brief)
                        .font(.callout)
                } else {
                    Text(briefTeaser)
                        .font(.callout)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if briefIsLong {
                    Button(briefExpanded ? "Show less" : "Show more") {
                        withAnimation { briefExpanded.toggle() }
                    }
                    .font(.footnote)
                }
            }
        }
    }

    /// Blank lines inside a four-line teaser just look like a rendering bug,
    /// so the collapsed form keeps the lines and drops the gaps.
    private var briefTeaser: String {
        controller.brief
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    private var briefIsLong: Bool {
        let brief = controller.brief
        return brief.count > 220 || brief.components(separatedBy: "\n").count > 4
    }

    private var liveSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                    Text(controller.headline)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Indeterminate on purpose: Hermes reports no percentage, and
                // a made-up one would be a lie with a progress bar around it.
                // SwiftUI's own linear bar draws an empty track here, which
                // reads as a very precise 0%, so this one moves instead.
                IndeterminateBar()
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now: \(controller.headline)")
        }
    }

    @ViewBuilder
    private var stepsSection: some View {
        let steps = controller.progress.steps
        if !steps.isEmpty {
            Section {
                if stepsExpanded {
                    ForEach(steps) { step in
                        StepRow(
                            step: step,
                            isExpanded: expandedStepIds.contains(step.id),
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if expandedStepIds.contains(step.id) {
                                        expandedStepIds.remove(step.id)
                                    } else {
                                        expandedStepIds.insert(step.id)
                                    }
                                }
                            }
                        )
                        .id(step.id)
                        .onAppear { if step.id == steps.last?.id { isAtBottom = true } }
                        .onDisappear { if step.id == steps.last?.id { isAtBottom = false } }
                    }
                }
            } header: {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { stepsExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.caption2)
                        Text(controller.progress.stepCountText)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(stepsExpanded ? 0 : -90))
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(controller.progress.stepCountText), \(stepsExpanded ? "expanded" : "collapsed")")
                .accessibilityHint("Shows or hides the steps")
            }
        }
    }

    @ViewBuilder
    private var noticeSection: some View {
        if let notice = controller.progress.incompleteNotice(isActive: controller.isActive) {
            Section {
                Label {
                    Text(notice)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let result = controller.result, !controller.isActive {
            Section("Result") {
                MarkdownText(source: result)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if controller.isActive {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Stop", role: .destructive) { confirmStop = true }
                    .accessibilityLabel("Stop this run")
            }
        } else if let result = controller.result {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: result) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button {
                        UIPasteboard.general.string = result
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share or copy this result")
            }
        }
    }

    /// The id is for debugging and for quoting to an assistant, not for reading:
    /// small, grey, selectable, and out of the way at the bottom.
    private var runIdFooter: some View {
        Section {
            EmptyView()
        } footer: {
            Text("Run \(controller.runId)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel("Run identifier \(controller.runId)")
        }
    }

    private var shortRunId: String {
        let id = controller.runId
        guard id.count > 14 else { return id }
        return "\(id.prefix(7))…\(id.suffix(5))"
    }
}

// MARK: - Layout

/// A row that becomes a column when the text gets large enough that a row
/// would have to throw one of its halves away.
struct AdaptiveStack<Content: View>: View {
    let vertical: Bool
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if vertical {
            VStack(alignment: .leading, spacing: spacing) { content }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

// MARK: - Indeterminate bar

/// A bar that admits it does not know how far along the run is. It has no
/// value to bind to and never will: Hermes reports no percentage.
struct IndeterminateBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travelling = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    if !reduceMotion {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: width * 0.34)
                            .offset(x: travelling ? width : -width * 0.34)
                    }
                }
                .clipShape(Capsule())
        }
        .frame(height: 4)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                travelling = true
            }
        }
        // The headline above already says what is happening, in words.
        .accessibilityHidden(true)
    }
}

// MARK: - Step row

struct StepRow: View {
    let step: RunStep
    let isExpanded: Bool
    let onToggle: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: step.category.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .padding(.top, 2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    // Side by side there is no room for both at accessibility
                    // sizes; the tool name would be sacrificed to the detail.
                    AdaptiveStack(vertical: dynamicTypeSize.isAccessibilitySize, spacing: 6) {
                        Text(step.toolLabel)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if !step.label.isEmpty {
                            Text(step.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if !step.preview.isEmpty {
                        Text(step.preview)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 1)
                            .truncationMode(truncation)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: isExpanded)
                    }
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 4) {
                    durationText
                    indicator
                }
                .padding(.top, 1)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(step.preview.isEmpty ? "" : "Shows the whole preview")
    }

    /// A URL loses its meaning from the front; a shell command loses it from
    /// the back.
    private var truncation: Text.TruncationMode {
        switch step.category {
        case .browser, .search: return .middle
        default: return .tail
        }
    }

    @ViewBuilder
    private var durationText: some View {
        if step.status == .running, step.durationMs == nil, step.startedAtDate != nil {
            // Ticks locally between polls so a long step does not look frozen.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(step.durationText(now: context.date) ?? "")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if let text = step.durationText() {
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Shape first, colour second: the state must survive a colour-blind eye
    /// and a monochrome screenshot.
    @ViewBuilder
    private var indicator: some View {
        switch step.status {
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)
        }
        // (accessibility text carries the same state in words)
    }

    private var accessibilityText: String {
        var parts = [step.toolLabel]
        if !step.preview.isEmpty { parts.append(step.preview) }
        else if !step.label.isEmpty { parts.append(step.label) }
        parts.append(step.status.rawValue)
        if let durationMs = step.durationMs {
            parts.append(RunStepFormat.spokenDuration(seconds: Double(durationMs) / 1000))
        } else if step.status == .running, let started = step.startedAtDate {
            parts.append(RunStepFormat.spokenDuration(seconds: Date().timeIntervalSince(started)))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Active") {
    NavigationStack {
        RunDetailView(run: RunProgressFixtures.activeRun, detail: RunProgressFixtures.active)
    }
    .preferredColorScheme(.dark)
}

#Preview("Finished") {
    NavigationStack {
        RunDetailView(
            run: RunProgressFixtures.finishedRun,
            detail: RunProgressFixtures.finished,
            result: RunProgressFixtures.resultText
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("No step history") {
    NavigationStack {
        RunDetailView(run: RunProgressFixtures.blindRun, detail: RunProgressFixtures.blind)
    }
    .preferredColorScheme(.dark)
}
#endif
