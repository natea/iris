//
//  SettingsView.swift
//  IrisLivePrototype
//
//  Everything that used to eat the top third of the main screen: the pairing
//  card, the developer API-key fallback, and the Debug readout. A standard
//  grouped form, because this is a settings screen and Liquid Glass belongs to
//  the floating control layer, not to every row of a list.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var pairing: PairingController
    @ObservedObject var session: LiveSessionController
    @ObservedObject var runs: RunsController
    @ObservedObject var voiceStore: VoiceChoiceStore
    @ObservedObject var preview: VoicePreviewController
    @ObservedObject var push: PushRegistrar
    @ObservedObject var liveActivity: LiveActivityController
    @ObservedObject var widgets: WidgetBridge

    @Binding var apiKey: String
    @Binding var keySaved: Bool
    @Binding var voice: String

    @Environment(\.dismiss) private var dismiss
    @AppStorage(Handedness.storageKey) private var handednessSetting = Handedness.right.rawValue
    @State private var showUnpairConfirm = false
    @State private var showDebug = false

    var body: some View {
        NavigationStack {
            Form {
                if let paired = pairing.paired {
                    pairedSection(paired)
                    voiceSection(paired)
                } else {
                    unpairedSection
                }

                answerButtonsSection

                notificationsSection

                liveActivitySection

                if pairing.paired == nil {
                    developerSection
                }

                debugSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await pairing.refreshStatus() }
            .confirmationDialog(
                "Unpair this phone?",
                isPresented: $showUnpairConfirm,
                titleVisibility: .visible
            ) {
                Button("Unpair this phone", role: .destructive) {
                    session.stop()
                    preview.stop()
                    // §11.2: tell the Mac to stop pushing while the credential
                    // still works.
                    Task { await push.unpairing() }
                    pairing.unpair()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the credential stored on this iPhone. To stop it working from the Mac's side too, revoke the device in Iris on the desktop.")
            }
        }
    }

    // MARK: Paired

    @ViewBuilder
    private func pairedSection(_ paired: PairedDesktop) -> some View {
        Section {
            LabeledContent {
                Text(paired.desktopName).foregroundStyle(.secondary)
            } label: {
                Label("Paired with", systemImage: "laptopcomputer.and.iphone")
            }

            LabeledContent {
                Text(paired.address)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            } label: {
                Text("Address")
            }

            // Two different outages, named as such: a failing request means
            // the Mac/tailnet is down; hermesReachable:false means the Mac is
            // up and Hermes is not.
            if let status = pairing.status {
                reachabilityRow("Iris on the Mac", ok: true)
                reachabilityRow("Hermes", ok: status.hermesReachable)
                if !status.liveModel.isEmpty {
                    LabeledContent("Model") {
                        Text(status.liveModel)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if !status.hermesReachable {
                    Text("You can still talk to Iris. Sending work to Hermes will be refused until it is running again.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } else if !pairing.statusMessage.isEmpty {
                Label(pairing.statusMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                HStack {
                    ProgressView().controlSize(.mini)
                    Text("Checking…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Your Mac")
        } footer: {
            Text("Sessions run on a single-use token minted by your Mac. No Gemini key is stored on this phone.")
        }

        Section {
            Button("Unpair this phone", role: .destructive) { showUnpairConfirm = true }
        }
    }

    private func reachabilityRow(_ name: String, ok: Bool) -> some View {
        LabeledContent(name) {
            Label(ok ? "Reachable" : "Not responding", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(ok ? Color.green : Color.orange)
                .labelStyle(.titleAndIcon)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Unpaired

    private var unpairedSection: some View {
        Section("Pair with your Mac") {
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Open Iris on your Mac.")
                step(2, "Go to Settings → Phone & devices → Pair a device.")
                step(3, "Scan the QR code with this iPhone's Camera app.")
                Text("Both devices must be signed in to the same Tailscale network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(.vertical, 4)

            if !pairing.message.isEmpty {
                Text(pairing.message)
                    .font(.footnote)
                    .foregroundStyle(pairing.messageIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(text)")
    }


    // MARK: Voice (LINK_API.md §13)

    /// The catalogue comes from the Mac (`GET /link/status` → `voices`); this
    /// screen never hardcodes a voice name. The choice is stored locally and
    /// sent with every session token — but only from the NEXT conversation,
    /// which the footer says out loud because §13.2 makes it true.
    @ViewBuilder
    private func voiceSection(_ paired: PairedDesktop) -> some View {
        let catalogue = pairing.status?.voices ?? []
        let macDefault = pairing.status?.defaultVoice ?? ""

        Section {
            // Above the rows, not under them: the greyed ▶ buttons are the
            // first thing seen, and the reason has to be on screen with them.
            if session.isRunning, !catalogue.isEmpty {
                Label(
                    "Iris is in a conversation, so previews are off. A conversation keeps the voice it started with.",
                    systemImage: "waveform"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if catalogue.isEmpty {
                Label(
                    pairing.status == nil
                        ? "Checking which voices your Mac has…"
                        : "This version of Iris on your Mac does not offer a voice list. Its own setting decides how Iris sounds.",
                    systemImage: pairing.status == nil ? "clock" : "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                // "Mac default (Zephyr)" is a real choice, not the absence of
                // one: picking it sends no `voice` at all, so the phone
                // follows whatever the Mac is set to from then on.
                voiceRow(
                    name: nil,
                    title: macDefault.isEmpty ? "Mac default" : "Mac default (\(macDefault))",
                    paired: paired,
                    previewName: macDefault
                )
                ForEach(catalogue) { voice in
                    voiceRow(name: voice.name, title: voice.label, paired: paired, previewName: voice.name)
                }
            }

            if let accent = pairing.status?.accent, !accent.isEmpty {
                LabeledContent("Accent") {
                    Text(accent).foregroundStyle(.secondary)
                }
                .accessibilityHint("Set in Iris on the Mac")
            }

            // Inline, in the section, rather than floating over a row: a
            // failure has to be readable without hiding the next voice.
            if let failure = preview.failure {
                Label("\(failure.voice): \(failure.message)", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !voiceStore.fallbackNotice.isEmpty {
                Label(voiceStore.fallbackNotice, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !session.isRunning, !preview.caption.isEmpty {
                Text(preview.caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Voice")
        } footer: {
            Text(voiceFooter)
        }
    }

    private var voiceFooter: String {
        let accentLine = (pairing.status?.accent).map { $0.isEmpty ? "" : " The accent is set in Iris on the Mac." } ?? ""
        return "A new voice applies from your next conversation — the one you are in keeps the voice it started with."
            + accentLine
    }

    @ViewBuilder
    private func voiceRow(name: String?, title: String, paired: PairedDesktop, previewName: String) -> some View {
        let isSelected = voiceStore.selected == name
        let isBusy = preview.isBusy(with: previewName)
        HStack(spacing: 12) {
            Button {
                voiceStore.select(name)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityIdentifier("voice-\(name ?? "mac-default")")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")

            if !previewName.isEmpty {
                Button {
                    preview.play(voice: previewName, paired: paired)
                } label: {
                    Group {
                        if isBusy {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "play.circle")
                                .font(.title3)
                        }
                    }
                    // The glyph alone is 19 pt square: a thumb misses it, and
                    // a miss to the left chooses the voice instead.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    // Reach, not height: the row stays as tall as its text.
                    .padding(.vertical, -11)
                }
                .buttonStyle(.plain)
                .disabled(session.isRunning || (preview.isBusy && !isBusy))
                .accessibilityLabel(isBusy ? "Stop the preview of \(previewName)" : "Hear \(previewName)")
                .accessibilityIdentifier("preview-\(previewName)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Answer buttons

    /// Which side the big "Yes" / "Approve" button sits on. A preference, not
    /// a secret, so it lives in UserDefaults next to the voice choice.
    private var answerButtonsSection: some View {
        Section {
            Picker("Button side", selection: $handednessSetting) {
                ForEach(Handedness.allCases) { hand in
                    Text(hand.title).tag(hand.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("handedness-picker")
        } header: {
            Text("Answer buttons")
        } footer: {
            Text("Puts the green Yes button on the side your thumb reaches most easily. The red No moves to the far side.")
        }
    }

    // MARK: Notifications

    /// Permission, registration and what the Mac can actually do (§11). Every
    /// line here is state that was observed, never a promise: a phone can be
    /// permitted and registered and still never buzz, because the Mac has no
    /// APNs key — and that is what `pushConfigured` is for.
    private var notificationsSection: some View {
        Section {
            LabeledContent("Permission") {
                Text(permissionLabel).font(.footnote).foregroundStyle(permissionColor)
            }
            .accessibilityElement(children: .combine)

            if pairing.paired != nil {
                LabeledContent("Push from your Mac") {
                    Text(push.stateLabel)
                        .font(.footnote)
                        .foregroundStyle(pushColor)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)

                LabeledContent("Your Mac can push") {
                    Text(macPushLabel).font(.footnote).foregroundStyle(macPushColor)
                }
                .accessibilityElement(children: .combine)

                if !push.tokenSummary.isEmpty {
                    LabeledContent("Device token") {
                        Text(push.tokenSummary)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
                }
            }

            switch runs.notifier.permission {
            case .granted:
                if pairing.paired != nil {
                    if push.isEnabled {
                        Button("Turn off notifications from your Mac", role: .destructive) {
                            Task { await push.disable() }
                        }
                    } else {
                        Button("Get notified by your Mac") {
                            Task { await push.enable(notifier: runs.notifier) }
                        }
                    }
                }
            case .denied, .unavailable:
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            case .unknown:
                Button("Allow notifications") {
                    Task {
                        // Paired: ask, then register with the Mac in one step.
                        // Unpaired: still worth asking — local banners for a
                        // finished run do not need a Mac.
                        if pairing.paired != nil {
                            await push.enable(notifier: runs.notifier)
                        } else {
                            await runs.notifier.requestPermissionIfNeeded()
                        }
                    }
                }
            }

            if let problem = push.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Your Mac sends a notification when a run you started here finishes, or when Hermes needs your answer. A run Iris is already reading out to you does not also buzz.")
        }
        .task {
            await runs.notifier.refreshPermission()
            push.noteStatus(pairing.status)
        }
    }

    // MARK: Live Activity and widget (LINK_API.md §14)

    /// Three facts and one switch. Every line is something that was observed —
    /// iOS's own permission, whether an activity is actually running, whether
    /// the Mac has been told how to update it — because "Live Activities: on"
    /// with no token registered is exactly the state that looks like it works
    /// and never updates.
    private var liveActivitySection: some View {
        Section {
            LabeledContent("Allowed by iOS") {
                Text(liveActivity.systemAllows ? "Yes" : "No")
                    .font(.footnote)
                    .foregroundStyle(liveActivity.systemAllows ? .green : .orange)
            }
            .accessibilityElement(children: .combine)

            Toggle(isOn: Binding(
                get: { liveActivity.isEnabled },
                set: { liveActivity.setEnabled($0) }
            )) {
                Text("Show Hermes on the Lock Screen")
            }
            .disabled(!liveActivity.systemAllows)
            .accessibilityIdentifier("live-activity-toggle")

            if liveActivity.isEnabled && liveActivity.systemAllows {
                LabeledContent("Live Activity") {
                    Text(liveActivity.stateLabel)
                        .font(.footnote)
                        .foregroundStyle(liveActivity.isStale ? .orange : .secondary)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)

                LabeledContent("Update token") {
                    Text(liveActivity.tokenSummary.isEmpty ? "Not registered" : liveActivity.tokenSummary)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)

                LabeledContent("Start-from-locked token") {
                    Text(liveActivity.startTokenSummary.isEmpty ? "Not registered" : liveActivity.startTokenSummary)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
            }

            if !liveActivity.systemAllows {
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }

            if let problem = liveActivity.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Home-screen widget") {
                Text(widgetStateLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Live Activity & widget")
        } footer: {
            Text(liveActivity.systemAllows
                 ? "The Lock Screen activity updates in real time while Hermes works, and says so when your Mac stops reporting. To add the widget: touch and hold the Home Screen, tap Edit › Add Widget, and search for Iris. The widget is refreshed by iOS on its own schedule, so it always shows how old its information is."
                 : "Live Activities are turned off for Iris in iOS Settings, so nothing will appear on the Lock Screen. The home-screen widget still works.")
        }
    }

    private var widgetStateLabel: String {
        guard widgets.isSharedStorageAvailable else { return "Shared storage unavailable" }
        guard let snapshot = widgets.currentSnapshot(), snapshot.paired else { return "No data yet" }
        if let age = snapshot.ageLine() { return age }
        return "Up to date"
    }

    private var pushColor: Color {
        switch push.state {
        case .registered: return .green
        case .failed: return .orange
        case .registering: return .secondary
        case .notRegistered: return .secondary
        }
    }

    private var macPushLabel: String {
        switch push.macPushConfigured {
        case .some(true): return "Set up"
        case .some(false): return "Not set up"
        case .none: return "Unknown"
        }
    }

    private var macPushColor: Color {
        switch push.macPushConfigured {
        case .some(true): return .green
        case .some(false): return .orange
        case .none: return .secondary
        }
    }

    private var permissionLabel: String {
        switch runs.notifier.permission {
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        case .unavailable: return "Unavailable"
        case .unknown: return "Not asked yet"
        }
    }

    private var permissionColor: Color {
        switch runs.notifier.permission {
        case .granted: return .green
        case .denied, .unavailable: return .orange
        case .unknown: return .secondary
        }
    }

    // MARK: Developer fallback

    private var developerSection: some View {
        Section {
            SecureField("Gemini API key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(session.isRunning)

            LabeledContent("Voice") {
                TextField("Voice", text: $voice)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing)
                    .disabled(session.isRunning)
            }

            if keySaved {
                Button("Forget key", role: .destructive) {
                    KeychainStore.deleteKey()
                    apiKey = ""
                    keySaved = false
                }
                .disabled(session.isRunning)
            }
        } header: {
            Text("Developer fallback")
        } footer: {
            Text("Only used while this phone is unpaired, and it talks to Gemini directly. A paired phone never holds a Gemini key, and its voice is chosen by the Mac.")
        }
    }

    // MARK: Debug

    /// "Mac build 8adda8d+ · started 23:44" — the first thing to check when a
    /// change to the Mac app does not seem to have taken effect.
    private var macBuildLine: String {
        guard let status = pairing.status else { return "Mac build: not connected" }
        guard !status.macBuild.isEmpty else { return "Mac build: unknown (this Mac app predates the build stamp — restart it)" }
        guard status.macStartedAtMs > 0 else { return "Mac build \(status.macBuild)" }
        let started = Date(timeIntervalSince1970: status.macStartedAtMs / 1000)
        return "Mac build \(status.macBuild) · started \(started.formatted(date: .omitted, time: .shortened)) (\(started.formatted(.relative(presentation: .named))))"
    }

    private var debugSection: some View {
        Section {
            DisclosureGroup("Debug", isExpanded: $showDebug) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(macBuildLine)
                    Divider()
                    Text(session.audioStatus.routeLine)
                    Text(session.audioStatus.engineLine)
                    Text("in \(session.audioChunksReceived) chunks · \(session.audioBytesReceived / 1024) KB → scheduled \(session.audioStatus.buffersScheduled) · dropped \(session.audioStatus.buffersDropped)")
                    Text("last route event: \(session.audioStatus.lastRouteChange)")
                    Text("last rebuild: \(session.audioStatus.lastRebuildReason)")
                    if !session.errorText.isEmpty {
                        Divider()
                        Text("last error (raw): \(session.errorText)")
                            .foregroundStyle(.red)
                    }
                    if !session.toolLog.isEmpty {
                        Divider()
                        ForEach(Array(session.toolLog.suffix(40).enumerated()), id: \.offset) { entry in
                            Text(entry.element)
                        }
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        } footer: {
            Text("Route, engine and tool lines, plus the exact text of the last failure.")
        }
    }
}
