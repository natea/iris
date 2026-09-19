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

                    VoiceOrb(state: voiceState, action: onToggleSession)

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

                    if let brief = pendingProposal {
                        PendingProposalCard(brief: brief)
                            .padding(.horizontal, 20)
                            .padding(.top, 18)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    ActiveRunsStrip(runs: allRuns, onOpen: onOpenRuns)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)

                    TranscriptView(lines: transcriptLines, placeholder: transcriptPlaceholder)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 12)
                }
            }

            VStack(spacing: 10) {
                Spacer()
                if !bannerText.isEmpty {
                    ErrorBanner(text: bannerText) { dismissedError = session.errorText }
                        .padding(.horizontal, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                controlBar
            }
            .padding(.bottom, 8)
        }
        .animation(.easeInOut(duration: 0.25), value: bannerText)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: pendingProposal)
        .navigationTitle("Iris")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: session.audioChunksReceived) { _, _ in noteIrisSpoke() }
        .onChange(of: session.isRunning) { _, running in
            if !running { isSpeaking = false; speechTimer?.cancel() }
        }
        .onDisappear { speechTimer?.cancel() }
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

    private var pendingProposal: String? {
        fixture?.pendingProposal ?? session.pendingProposal
    }

    private var transcriptLines: [LiveSessionController.TranscriptLine] {
        fixture?.lines ?? session.lines
    }

    private var transcriptPlaceholder: String {
        switch voiceState {
        case .unavailable: return "Once this phone is paired, what you say and what Iris says will appear here."
        case .idle: return "What you say and what Iris says will appear here."
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
        if session.pendingProposal != nil { return .awaitingAnswer }

        guard session.isRunning else { return .idle }

        switch session.status {
        case .authorizing, .connecting:
            return .connecting
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
struct PendingProposalCard: View {
    let brief: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nothing sent yet", systemImage: "hand.raised.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
            Text(brief)
                .font(.subheadline)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
            Text("Say yes to send, or no to cancel.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .irisGlass(.tinted(.orange.opacity(0.30)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for your answer. Nothing has been sent to Hermes yet.")
        .accessibilityValue("\(brief). Say yes to send, or no to cancel.")
    }
}
