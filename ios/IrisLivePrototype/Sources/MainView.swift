//
//  MainView.swift
//  IrisLivePrototype
//
//  The screen the app opens on: background, orb, one line of status, the
//  transcript, and a floating glass control bar. Everything a developer needed
//  and a user did not — pairing, keys, debug — moved to Settings.
//
//  Layering follows Apple's "Adopting Liquid Glass" guidance: content (the
//  transcript) sits flat under a floating control layer (the orb, the bar, the
//  banner) which is the only thing made of glass. Glass is never stacked on
//  glass, and the transcript is deliberately not in it.
//

import SwiftUI

struct MainView: View {
    @ObservedObject var session: LiveSessionController
    @ObservedObject var pairing: PairingController
    @ObservedObject var runs: RunsController

    /// True when the developer fallback has a key, so the orb is live while
    /// unpaired.
    var hasDeveloperKey: Bool
    var onToggleSession: () -> Void
    var onOpenSettings: () -> Void
    var onOpenRuns: () -> Void

    /// DEBUG launch-argument fixtures. nil on every production path.
    var fixture: PreviewFixture?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Which side the "Yes" button sits on (Settings → Answer buttons).
    @AppStorage(Handedness.storageKey) private var handednessSetting = Handedness.right.rawValue
    @State private var isSpeaking = false
    @State private var speechTimer: Task<Void, Never>?
    @State private var dismissedError = ""

    var body: some View {
        ZStack {
            AuroraBackground()

            if voiceState == .unavailable {
                // Nothing to say and nothing to start: one explanation,
                // centred, and no dead controls around it.
                unpairedEmptyState
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 8)

                    // Smaller while a question is on screen: the brief and
                    // the buttons are what the moment is about.
                    VoiceOrb(
                        state: voiceState,
                        compact: pendingProposal != nil || approvalOnScreen != nil,
                        action: onToggleSession
                    )

                    Text(voiceState.headline)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                        .padding(.top, 10)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: voiceState)
                        .accessibilityHidden(true)   // the orb already says this

                    if let proposal = pendingProposal {
                        PendingProposalCard(brief: proposal.task, failure: proposalError)
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                            // The brief outranks the transcript for space:
                            // without this the stack squeezed the scrolling
                            // card down to two clipped lines (seen in the
                            // simulator), which is the one thing this card
                            // must never do while a tap can send it.
                            .layoutPriority(1)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if let waiting = approvalOnScreen {
                        // Never both at once: a staged proposal is about work
                        // that has not started, the approval is about work
                        // that is blocked, and two sets of big buttons in the
                        // same thumb zone is how the wrong one gets hit. The
                        // approval stays reachable from the run and its push.
                        PendingApprovalCard(
                            approval: waiting.approval,
                            note: approvalMessage,
                            onOpenRun: onOpenRuns
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .layoutPriority(1)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // At accessibility text sizes the card and the two rows
                    // of buttons already fill the screen, so the strip gives
                    // up its room rather than being pushed under them. The
                    // runs are still one tap away in the control bar.
                    if !(dynamicTypeSize.isAccessibilitySize && answerBarClearance > 0) {
                        ActiveRunsStrip(runs: allRuns, onOpen: onOpenRuns)
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                    }

                    TranscriptView(lines: transcriptLines, placeholder: transcriptPlaceholder)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 12)
                }
                // Room for whatever the floating layer is showing, so the
                // transcript never slides underneath the answer buttons.
                .padding(.bottom, answerBarClearance)
            }

            VStack(spacing: 10) {
                Spacer()
                if !bannerText.isEmpty {
                    ErrorBanner(text: bannerText) { dismissedError = session.errorText }
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // The thumb zone. The answer bar sits directly above the
                // control bar rather than replacing it: the route picker is
                // how AirPods get chosen, and losing it mid-conversation to
                // answer a question would be its own bug.
                if let proposal = pendingProposal {
                    answerBar(for: proposal)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let waiting = approvalOnScreen {
                    approvalBar(for: waiting)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                controlBar
            }
            .padding(.bottom, 8)
        }
        .animation(.easeInOut(duration: 0.25), value: bannerText)
        // Reduce Motion gets a plain cross-fade rather than the spring: these
        // arrive under the reader's thumb, and a bounce there is exactly the
        // motion the setting exists to remove.
        .animation(answerTransition, value: pendingProposal)
        .animation(answerTransition, value: approvalOnScreen?.approval.requestId)
        .navigationTitle("Iris")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: session.audioChunksReceived) { _, _ in noteIrisSpoke() }
        .onChange(of: session.isRunning) { _, running in
            if !running { isSpeaking = false; speechTimer?.cancel() }
        }
        .onDisappear { speechTimer?.cancel() }
    }

    // MARK: The answer buttons

    /// The whole point of these: answering Hermes without aiming precisely and
    /// without using your voice.
    ///
    /// SECURITY INVARIANT: these three closures are the ONLY way into
    /// `answerPendingProposal`, and through it into the gate's user-control
    /// claim. Nothing the model emits reaches them. See the matching comments
    /// in DispatchGate.swift, ToolRouter.swift and ContentView.swift.
    private func answerBar(for proposal: StagedProposal) -> some View {
        AnswerButtonBar(
            affirmative: AnswerAction(
                id: "answer-yes",
                title: "Yes",
                symbol: "checkmark.circle.fill",
                role: .affirmative,
                accessibilityLabel: "Yes, send this to Hermes",
                accessibilityHint: "Sends the brief shown above, exactly as it is",
                isBusy: session.isAnsweringProposal
            ) { answer(.yes) },
            negative: AnswerAction(
                id: "answer-no",
                title: "No",
                symbol: "xmark.circle.fill",
                role: .negative,
                accessibilityLabel: "No, don't send",
                accessibilityHint: "Discards it. Nothing goes to Hermes"
            ) { answer(.no) },
            tertiary: AnswerAction(
                id: "answer-explain",
                title: "Let me explain",
                symbol: "text.bubble.fill",
                role: .tertiary,
                accessibilityLabel: "Let me explain a change",
                accessibilityHint: "Iris stops and listens. Nothing is sent and the request stays as it is"
            ) { answer(.explain) },
            handedness: handedness,
            isDisabled: session.isAnsweringProposal
        )
        .id(proposal.id)
    }

    private func answer(_ choice: ProposalAnswer) {
        session.answerPendingProposal(choice)
    }

    private var handedness: Handedness {
        Handedness(rawValue: handednessSetting) ?? .right
    }

    private var answerTransition: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.4, dampingFraction: 0.85)
    }

    /// How much room the floating answer bar needs above the control bar.
    ///
    /// The transcript already keeps 96pt clear for the control bar, so this is
    /// only the bar's own height — but at accessibility text sizes the bar
    /// stacks its buttons vertically and becomes three times as tall, which
    /// put it straight over the card it was answering (seen in the simulator).
    private var answerBarClearance: CGFloat {
        let big = dynamicTypeSize.isAccessibilitySize
        if pendingProposal != nil { return big ? 232 : 86 }
        if approvalOnScreen != nil { return big ? 168 : 86 }
        return 0
    }

    // MARK: The approval buttons

    /// The run Hermes is blocked on, when this phone can answer it. Nil while
    /// a proposal is staged: one question in the thumb zone at a time.
    private var approvalOnScreen: (run: LinkTask, approval: PendingApproval)? {
        guard pendingProposal == nil else { return nil }
        guard let run = allRuns.first(where: {
            !$0.isTerminal && ($0.pendingApproval?.canApproveFromPhone ?? false)
        }), let approval = run.pendingApproval else { return nil }
        return (run, approval)
    }

    private var approvalMessage: String {
        fixture == nil ? runs.approvalMessage : ""
    }

    /// SECURITY INVARIANT: these two closures are the only callers of
    /// `RunsController.answerApproval` from this screen. Approve means ALLOW
    /// ONCE and answers the command shown in full on the card above it; the
    /// grants that authorize future commands are not here — they are behind
    /// "More options…" on the run screen, with a confirmation.
    private func approvalBar(for waiting: (run: LinkTask, approval: PendingApproval)) -> some View {
        AnswerButtonBar(
            affirmative: AnswerAction(
                id: "approval-approve",
                title: "Approve",
                symbol: "checkmark.shield.fill",
                role: .affirmative,
                accessibilityLabel: "Approve: \(RunTitle.summary(of: waiting.approval.summary))",
                accessibilityHint: "Lets Hermes run this one command",
                isBusy: runs.sendingApproval == .once
            ) {
                Task { await runs.answerApproval(.once, approval: waiting.approval, runId: waiting.run.runId) }
            },
            negative: AnswerAction(
                id: "approval-deny",
                title: "Deny",
                symbol: "xmark.shield.fill",
                role: .negative,
                accessibilityLabel: "Deny",
                accessibilityHint: "Tells Hermes no",
                isBusy: runs.sendingApproval == .deny
            ) {
                Task { await runs.answerApproval(.deny, approval: waiting.approval, runId: waiting.run.runId) }
            },
            handedness: handedness,
            isDisabled: runs.sendingApproval != nil
        )
        .id(waiting.approval.requestId)
    }

    // MARK: Control layer

    /// Settings, Runs and the route picker sit together, so they live in one
    /// `GlassEffectContainer` and read as a single piece of material.
    private var controlBar: some View {
        // No GlassEffectContainer: with the glass behind the controls, the
        // container composited the icons INTO the glass and blurred them (seen on
        // device). One glass shape needs no container.
        Group {
            HStack(spacing: 6) {
                // The route picker is how AirPods get chosen. It stays here,
                // one tap from the orb, and never moves to Settings.
                RoutePicker(tint: .primary)
                    .frame(width: 30, height: 30)
                    .frame(width: 56, height: 52)
                    .accessibilityLabel("Choose audio output")

                Divider().frame(height: 22).opacity(0.4)

                Button(action: onOpenRuns) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 56, height: 52)
                            .contentShape(Rectangle())
                        if activeRunCount > 0 {
                            Text("\(activeRunCount)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange, in: Capsule())
                                .offset(x: -6, y: 8)
                        }
                    }
                }
                .accessibilityLabel("Runs")
                .accessibilityIdentifier("open-runs")
                .accessibilityValue(activeRunCount > 0 ? "\(activeRunCount) active" : "none active")

                Divider().frame(height: 22).opacity(0.4)

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 56, height: 52)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("open-settings")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .padding(.horizontal, 4)
            // Glass sits behind the controls rather than wrapping them: wrapped,
            // the effect layer swallowed taps meant for the buttons (seen on device).
            .background { Color.clear.irisGlass(.regular, in: Capsule()) }
            // Toolbar-scale controls: 44pt targets are fixed, so an
            // accessibility text size must not blow the capsule apart.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
        }
    }

    // MARK: Unpaired first run

    private var unpairedEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(.secondary)

            Text("Pair this phone with your Mac")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Open Iris on the Mac, go to Settings → Phone & devices → Pair a device, then scan the QR code with the Camera app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("How to pair", action: onOpenSettings)
                .irisGlassButtonStyle(prominent: true)
                .controlSize(.large)
                .padding(.top, 6)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 80)   // clear of the floating control bar
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    // MARK: Derived state

    private var allRuns: [LinkTask] {
        if let fixture { return fixture.runs }
        return session.runs.isEmpty ? runs.runs : session.runs
    }

    private var activeRunCount: Int { allRuns.filter { !$0.isTerminal }.count }

    private var pendingProposal: StagedProposal? {
        if let fixture {
            // A fixture has no gate behind it, so its id is a fixed one that
            // matches nothing real — a tap on a preview can never dispatch.
            return fixture.pendingProposal.map {
                StagedProposal(id: "preview-proposal", task: $0)
            }
        }
        return session.pendingProposal
    }

    private var proposalError: String {
        fixture == nil ? session.proposalError : ""
    }

    private var transcriptLines: [LiveSessionController.TranscriptLine] {
        fixture?.lines ?? session.lines
    }

    private var transcriptPlaceholder: String {
        switch voiceState {
        case .unavailable: return "Once this phone is paired, what you say and what Iris says will appear here."
        case .idle: return "What you say and what Iris says will appear here."
        case .reconnecting: return "Reconnecting. Your conversation is being picked back up."
        default: return "Listening. Say something."
        }
    }

    private var bannerText: String {
        if let fixture { return fixture.errorText.map(ErrorPresentation.humanize) ?? "" }
        let raw = session.errorText
        guard !raw.isEmpty, raw != dismissedError else { return "" }
        return ErrorPresentation.humanize(raw)
    }

    /// One place where controller state becomes something a person can read.
    /// Priority: the gate first (nothing has been sent), then Iris's own
    /// voice, then Hermes, then the plain session status.
    private var voiceState: VoiceState {
        if let fixture { return fixture.state }

        if pairing.paired == nil && !hasDeveloperKey { return .unavailable }
        // Reconnecting outranks the gate: the staged proposal is being
        // invalidated anyway, and "Waiting for your answer" would be a lie
        // while there is no connection to answer over.
        if session.status == .reconnecting && session.isRunning { return .reconnecting }
        if session.pendingProposal != nil { return .awaitingAnswer }

        guard session.isRunning else { return .idle }

        switch session.status {
        case .authorizing, .connecting:
            return .connecting
        case .reconnecting:
            return .reconnecting
        case .ready:
            if isSpeaking { return .speaking }
            if activeRunCount > 0 { return .working(activeRunCount) }
            return .listening
        case .idle, .closed:
            return .idle
        }
    }

    /// Playback chunks are the one signal already on the main actor that says
    /// Iris is talking. No new audio tap is added for this.
    private func noteIrisSpoke() {
        guard session.isRunning else { return }
        if !isSpeaking { isSpeaking = true }
        speechTimer?.cancel()
        speechTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            isSpeaking = false
        }
    }
}

// MARK: - Pending proposal

/// While this is on screen, nothing has been sent to Hermes yet.
///
/// The brief is shown IN FULL. It used to be clipped at five lines with an
/// ellipsis, which was survivable when the only way to answer was to say yes
/// out loud after hearing it read back — and is not survivable now that one
/// tap sends it. Nobody confirms text they cannot see, so the card scrolls
/// within a bounded height instead of truncating.
struct PendingProposalCard: View {
    let brief: String
    /// Why the last tap sent nothing. Empty when nothing has failed.
    var failure: String = ""

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var measuredBrief: CGFloat = 0

    /// Tall enough for a typical Goal/Context brief, short enough to leave
    /// the orb, the transcript and the buttons their room — and SMALLER at
    /// accessibility sizes, not larger, because the bar takes two rows there
    /// and the card still has to fit above it.
    private var maxBriefHeight: CGFloat { dynamicTypeSize.isAccessibilitySize ? 130 : 168 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Nothing sent yet", systemImage: "hand.raised.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)

            ScrollView(.vertical) {
                MarkdownText(source: brief)
                    .padding(.trailing, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MeasuredHeight())
            }
            .frame(maxWidth: .infinity)
            // An EXPLICIT height, not a maximum: a ScrollView's ideal height
            // is tiny, so `maxHeight` let the surrounding stack squeeze the
            // brief down to two clipped lines (seen in the simulator). It
            // takes exactly what the text needs, up to the cap, and scrolls
            // for the rest.
            .frame(height: min(max(measuredBrief, 44), maxBriefHeight))
            .onPreferenceChange(BriefHeightKey.self) { measuredBrief = $0 }
            .scrollBounceBehavior(.basedOnSize)
            // One element carrying the WHOLE brief: VoiceOver must be able to
            // read what a tap would send, not just the part on screen.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("proposal-brief")
            .accessibilityLabel(brief)

            if isLong {
                Label("Scroll to read all of it", systemImage: "arrow.up.and.down")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            if failure.isEmpty {
                Text("Tap an answer below — or just say yes or no.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("proposal-failure")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .irisGlass(.tinted(.orange.opacity(0.30)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waiting for your answer. Nothing has been sent to Hermes yet.")
    }

    /// A rough measure, not a layout one: it only decides whether to offer the
    /// hint, and being wrong shows one extra line of guidance.
    private var isLong: Bool {
        brief.count > 220 || brief.components(separatedBy: "\n").count > 5
    }
}

/// Reports how tall the text inside a scrolling card really is, so the card
/// can ask for exactly that (up to its cap) instead of being squeezed.
private struct BriefHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MeasuredHeight: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: BriefHeightKey.self, value: proxy.size.height)
        }
    }
}

// MARK: - Pending approval (LINK_API.md §11.5)

/// Hermes is blocked on this run and this phone can answer it. Same place and
/// same shape as the proposal card, because it is the same kind of moment: a
/// question waiting on the user, with the complete text of what is being
/// answered on screen above the buttons.
struct PendingApprovalCard: View {
    let approval: PendingApproval
    /// What the last answer did, in plain words. Empty when nothing has been
    /// answered yet.
    var note: String = ""
    var onOpenRun: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var measuredSummary: CGFloat = 0

    private var maxSummaryHeight: CGFloat { dynamicTypeSize.isAccessibilitySize ? 150 : 200 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hermes is waiting for you", systemImage: "hand.raised.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)

            // Hermes' own words: shown, never followed. Monospaced because
            // these are commands, and bounded rather than clipped — nobody
            // approves what they cannot read.
            ScrollView(.vertical) {
                Text(approval.summary)
                    .font(.callout.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MeasuredHeight())
            }
            .frame(maxWidth: .infinity)
            .frame(height: min(max(measuredSummary, 30), maxSummaryHeight))
            .onPreferenceChange(BriefHeightKey.self) { measuredSummary = $0 }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("approval-summary")
            .accessibilityLabel(approval.summary)

            if isLongCommand {
                Label("Scroll to read all of it", systemImage: "arrow.up.and.down")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            if note.isEmpty {
                // Side by side normally; stacked at accessibility sizes,
                // where the row truncated both halves into ellipses.
                let hint = Text("Approve runs this one command.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                let open = Button("Open the run", action: onOpenRun)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("approval-open-run")
                    .accessibilityHint("Shows the steps, and the broader permissions")

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        hint.fixedSize(horizontal: false, vertical: true)
                        open
                    }
                } else {
                    HStack(spacing: 10) {
                        hint
                        Spacer(minLength: 0)
                        open
                    }
                }
            } else {
                Label(note, systemImage: "info.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("approval-note")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .irisGlass(.tinted(.orange.opacity(0.30)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hermes is waiting for you.")
    }

    private var isLongCommand: Bool {
        approval.summary.count > 160 || approval.summary.components(separatedBy: "\n").count > 3
    }
}
