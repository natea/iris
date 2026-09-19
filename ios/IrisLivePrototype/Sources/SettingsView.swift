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

    @Binding var apiKey: String
    @Binding var keySaved: Bool
    @Binding var voice: String

    @Environment(\.dismiss) private var dismiss
    @State private var showUnpairConfirm = false
    @State private var showDebug = false

    var body: some View {
        NavigationStack {
            Form {
                if let paired = pairing.paired {
                    pairedSection(paired)
                } else {
                    unpairedSection
                }

                notificationsSection

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

    // MARK: Notifications

    private var notificationsSection: some View {
        Section {
            LabeledContent("When a run finishes") {
                Text(permissionLabel).font(.footnote).foregroundStyle(permissionColor)
            }
            .accessibilityElement(children: .combine)

            switch runs.notifier.permission {
            case .granted:
                EmptyView()
            case .denied, .unavailable:
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            case .unknown:
                Button("Allow notifications") {
                    Task { await runs.notifier.requestPermissionIfNeeded() }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Without this, a run that finishes while Iris is closed waits in the Runs list instead of buzzing.")
        }
        .task { await runs.notifier.refreshPermission() }
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

    private var debugSection: some View {
        Section {
            DisclosureGroup("Debug", isExpanded: $showDebug) {
                VStack(alignment: .leading, spacing: 4) {
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
