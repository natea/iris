//
//  ContentView.swift
//  IrisLivePrototype
//
//  Two ways in:
//
//    Paired (the real path) — the phone scanned an `iris-link://pair` QR from
//    the Iris desktop, holds its own device credential, and fetches a fresh
//    single-use Gemini token from the Mac immediately before each session. No
//    Gemini API key is ever on the phone.
//
//    Unpaired (developer fallback) — paste a key and talk directly to Gemini.
//    Only available while unpaired, and labelled as what it is.
//
//  No secret in this file is ever printed, logged, or put in an error string.
//

import SwiftUI
import AVKit
import UIKit

// MARK: - Pairing

@MainActor
final class PairingController: ObservableObject {

    /// The stored pairing, or nil when this phone is unpaired.
    @Published private(set) var paired: PairedDesktop?
    /// A scanned offer waiting for the user to compare codes and tap Pair.
    @Published var pendingOffer: PairingOffer?
    @Published var isPairing = false
    @Published var message: String = ""
    /// Red when the message is a refusal rather than progress.
    @Published var messageIsError = false
    @Published private(set) var status: LinkStatus?
    @Published private(set) var statusMessage: String = ""

    init() {
        paired = KeychainStore.loadPairing()
    }

    var isPaired: Bool { paired != nil }

    // MARK: Deep link

    /// Called from `.onOpenURL`. Parsing is strict and the failure is shown to
    /// the user — a refused link is a security event, not a silent no-op.
    func handle(url: URL) {
        do {
            let offer = try IrisLinkDeepLink.parse(url)
            message = ""
            messageIsError = false
            pendingOffer = offer
        } catch let error as PairingLinkError {
            pendingOffer = nil
            messageIsError = true
            message = error.message
        } catch {
            pendingOffer = nil
            messageIsError = true
            message = "That pairing link could not be read."
        }
    }

    // MARK: Pair / unpair

    func confirmPair() async {
        guard let offer = pendingOffer, !isPairing else { return }
        isPairing = true
        message = ""
        messageIsError = false
        defer { isPairing = false }
        do {
            let result = try await LinkClient.pair(
                host: offer.host,
                port: offer.port,
                secret: offer.secret,
                deviceName: UIDevice.current.name
            )
            let record = PairedDesktop(
                host: offer.host,
                port: offer.port,
                deviceId: result.deviceId,
                credential: result.credential,
                desktopName: offer.desktopName
            )
            guard KeychainStore.savePairing(record) else {
                messageIsError = true
                message = "Pairing succeeded but this phone could not store the credential in its Keychain."
                return
            }
            paired = record
            pendingOffer = nil
            message = "Paired with \(record.desktopName)."
            await refreshStatus()
        } catch let error as LinkError {
            messageIsError = true
            message = error.message
        } catch {
            messageIsError = true
            message = "Pairing failed."
        }
    }

    func cancelPending() {
        pendingOffer = nil
    }

    /// Local only: forgets the credential on this phone. The desktop's own
    /// revoke button is what removes it on that side.
    func unpair() {
        KeychainStore.deletePairing()
        paired = nil
        status = nil
        statusMessage = ""
        message = "This phone is no longer paired."
        messageIsError = false
    }

    // MARK: Status

    func refreshStatus() async {
        guard let paired else { return }
        do {
            status = try await LinkClient(paired: paired).status()
            statusMessage = ""
        } catch let error as LinkError {
            status = nil
            handle(linkError: error)
        } catch {
            status = nil
            statusMessage = "Could not reach Iris on your Mac."
        }
    }

    /// The one place a refusal becomes a state change. A revoked or unknown
    /// credential clears the pairing and says so — never an empty result and
    /// never dressed up as a network problem.
    func handle(linkError error: LinkError) {
        if error.clearsPairing {
            KeychainStore.deletePairing()
            paired = nil
            status = nil
            messageIsError = true
            message = error.message
            statusMessage = ""
        } else {
            statusMessage = error.message
        }
    }
}

// MARK: - Live session

@MainActor
final class LiveSessionController: ObservableObject {

    enum Status: String {
        case idle = "Idle"
        case authorizing = "Getting a token from your Mac…"
        case connecting = "Connecting…"
        case ready = "Live"
        case closed = "Closed"
    }

    struct TranscriptLine: Identifiable {
        let id = UUID()
        let speaker: String
        var text: String
    }

    @Published var status: Status = .idle
    @Published var lines: [TranscriptLine] = []
    @Published var errorText: String = ""
    @Published var audioChunksReceived: Int = 0
    @Published var audioBytesReceived: Int = 0
    @Published var isRunning = false
    /// Route + engine diagnostics, polled off the audio engine.
    @Published var audioStatus = AudioStatus()

    /// The staged brief while the dispatch gate waits for the user's answer.
    @Published var pendingProposal: String?
    /// Runs in the pinned Hermes session, desktop-dispatched ones included.
    @Published var runs: [LinkTask] = []
    /// Tool / system-event lines, newest last. Collapsible in the UI.
    @Published var toolLog: [String] = []
    /// The run whose completion is currently being spoken.
    @Published var announcingRunId: String?

    /// Raised when the Link service refuses this phone, so the view can drop
    /// back to the pairing flow.
    var onLinkError: ((LinkError) -> Void)?

    private var client: LiveClient?
    private var pump: Task<Void, Never>?
    private var statusPoll: Task<Void, Never>?
    private var starter: Task<Void, Never>?
    private let audio = AudioEngine()
    /// Present only in paired mode: the gate, the tool router, run polling
    /// and the contract's system events all live in here.
    private var coordinator: SessionCoordinator?
    private var pairedDesktop: PairedDesktop?
    /// Raised when a run this phone dispatched finishes, so the app can stop
    /// double-notifying about something Iris just said out loud.
    var onRunAnnounced: ((String) -> Void)?

    // MARK: Start

    /// The paired path: fetch a single-use token from the Mac, then connect
    /// with it. The token is never stored and never reused — it is minted with
    /// `uses: 1` and a 60 s window to start a session.
    func startWithLink(paired: PairedDesktop, model: String) {
        guard !isRunning else { return }
        reset()
        pairedDesktop = paired
        status = .authorizing
        isRunning = true
        starter = Task { [weak self] in
            guard let self else { return }
            do {
                let minted = try await LinkClient(paired: paired).geminiToken()
                guard !Task.isCancelled else { return }
                self.begin(
                    credential: .ephemeralToken(minted.token),
                    model: minted.model.isEmpty ? model : minted.model,
                    voice: ""
                )
            } catch let error as LinkError {
                self.isRunning = false
                self.status = .idle
                self.errorText = error.message
                self.onLinkError?(error)
            } catch {
                self.isRunning = false
                self.status = .idle
                self.errorText = "Could not get a session token from your Mac."
            }
        }
    }

    /// Developer fallback, unpaired only.
    func start(apiKey: String, voice: String) {
        guard !isRunning else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorText = "Paste an API key first, or pair this phone with your Mac."
            return
        }
        reset()
        pairedDesktop = nil
        isRunning = true
        begin(credential: .apiKey(key), model: nil, voice: voice)
    }

    private func reset() {
        errorText = ""
        lines = []
        audioChunksReceived = 0
        audioBytesReceived = 0
        audioStatus = AudioStatus()
        pendingProposal = nil
        toolLog = []
        announcingRunId = nil
    }

    private func begin(credential: LiveClient.Credential, model: String?, voice: String) {
        status = .connecting
        startStatusPolling()

        let config: LiveClient.Config
        if let paired = pairedDesktop {
            // Everything that decides who Iris is — voice, prompt, tools —
            // is baked into the token by the Mac. The phone only opens the
            // socket and answers the tool calls.
            config = .init(
                credential: credential,
                model: model?.isEmpty == false ? model! : "models/gemini-3.1-flash-live-preview",
                minimalSetup: true
            )
            _ = paired
        } else {
            let instruction = "You are a terse voice assistant. Answer in one or two short sentences unless asked for more."
            if let model, !model.isEmpty {
                config = .init(
                    credential: credential,
                    model: model,
                    voiceName: voice,
                    systemInstruction: instruction
                )
            } else {
                config = .init(credential: credential, voiceName: voice, systemInstruction: instruction)
            }
        }
        let client = LiveClient(config: config)
        self.client = client

        if let paired = pairedDesktop {
            let sink: @Sendable (CoordinatorEvent) -> Void = { [weak self] event in
                Task { @MainActor in self?.apply(coordinatorEvent: event) }
            }
            coordinator = SessionCoordinator(
                link: LinkClient(paired: paired),
                transport: client,
                userName: "the user",
                notify: sink
            )
        } else {
            coordinator = nil
        }

        pump = Task { [weak self] in
            guard let self else { return }
            let stream = await client.events()
            await client.connect()
            for await event in stream {
                await self.apply(event)
            }
            await MainActor.run { self.status = .closed }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        starter?.cancel()
        starter = nil
        statusPoll?.cancel()
        statusPoll = nil
        audio.stop()
        audioStatus = audio.currentStatus()
        let coordinator = self.coordinator
        self.coordinator = nil
        Task { await coordinator?.close() }
        let client = self.client
        self.client = nil
        pump?.cancel()
        pump = nil
        Task { await client?.close() }
        status = .closed
    }

    private func apply(_ event: LiveEvent) async {
        // Ordered hand-off; returns as soon as the event is queued, so a slow
        // tool call or a run poll can never stall audio.
        if let coordinator { await coordinator.submit(event) }

        switch event {
        case .opened:
            status = .connecting

        case .setupComplete:
            status = .ready
            await startMicrophone()

        case .audio(let pcm):
            audioChunksReceived += 1
            audioBytesReceived += pcm.count
            audio.enqueuePlayback(pcm)

        case .inputTranscript(let text):
            append(speaker: "You", text: text)

        case .outputTranscript(let text):
            append(speaker: "Iris", text: text)

        case .text(let text):
            append(speaker: "Iris", text: text)

        case .interrupted:
            audio.flushPlayback()
            lines.append(.init(speaker: "—", text: "[interrupted]"))

        case .generationComplete:
            break

        case .turnComplete:
            lines.append(.init(speaker: "—", text: "[turn complete]"))

        case .goAway(let timeLeft):
            errorText = "Server going away (\(timeLeft ?? "soon"))"

        case .sessionResumption:
            break

        case .toolCall(let calls):
            // Execution belongs to the coordinator; the UI only shows it.
            for call in calls { toolLog.append("↳ \(call.name)") }

        case .toolCallCancellation(let ids):
            toolLog.append("↳ cancelled \(ids.count) tool call(s)")

        case .authorizationFailed(let code, let reason):
            // Not a network error and not something to retry: the token was
            // refused. Say so, and stop.
            errorText = "Gemini refused this session's token (close \(code)"
                + (reason.map { ": \($0)" } ?? "")
                + "). Tap Start to ask your Mac for a fresh one."

        case .error(let message):
            errorText = message

        case .closed(let code, let reason):
            status = .closed
            isRunning = false
            statusPoll?.cancel()
            statusPoll = nil
            audio.stop()
            if errorText.isEmpty {
                errorText = "Closed (code \(code))" + (reason.map { ": \($0)" } ?? "")
            }
        }
    }

    /// Everything the coordinator learns is surfaced here and nowhere else.
    private func apply(coordinatorEvent event: CoordinatorEvent) {
        switch event {
        case .log(let line):
            toolLog.append(line)
            if toolLog.count > 200 { toolLog.removeFirst(toolLog.count - 200) }
        case .pendingProposal(let brief):
            pendingProposal = brief
        case .runs(let list):
            runs = list
        case .toolCompleted(let name, _):
            toolLog.append("↳ \(name) answered")
        case .announcing(let runId, let status):
            announcingRunId = runId
            lines.append(.init(speaker: "—", text: "[Hermes \(status): announcing \(runId)]"))
        case .announced(let runId):
            if announcingRunId == runId { announcingRunId = nil }
            onRunAnnounced?(runId)
        case .linkError(let error):
            errorText = error.message
            onLinkError?(error)
        }
    }

    /// Pull-to-refresh and the foreground path both land here.
    func refreshRuns() async {
        if let coordinator {
            await coordinator.refreshRuns()
            return
        }
        guard let paired = pairedDesktop ?? KeychainStore.loadPairing() else { return }
        do {
            runs = try await LinkClient(paired: paired).listTasks(undelivered: false)
        } catch let error as LinkError {
            errorText = error.message
            if error.clearsPairing { onLinkError?(error) }
        } catch {
            errorText = "Could not list Hermes runs."
        }
    }

    private func startMicrophone() async {
        let granted = await audio.requestMicrophonePermission()
        guard granted else {
            errorText = "Microphone permission denied."
            return
        }
        audio.onError = { [weak self] message in
            Task { @MainActor in self?.errorText = message }
        }
        audio.onCapturedChunk = { [weak self] chunk in
            Task { [weak self] in
                guard let client = await self?.currentClient else { return }
                await client.sendAudio(chunk)
            }
        }
        audio.start()
    }

    /// The audio engine owns its own serial queue, so the UI samples it
    /// rather than being pushed to from the audio thread.
    private func startStatusPolling() {
        statusPoll?.cancel()
        statusPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = self.audio.currentStatus()
                if snapshot != self.audioStatus { self.audioStatus = snapshot }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private var currentClient: LiveClient? { client }

    /// Appends to the trailing line when the same speaker keeps streaming —
    /// transcription arrives in small fragments.
    private func append(speaker: String, text: String) {
        if var last = lines.last, last.speaker == speaker {
            last.text += text
            lines[lines.count - 1] = last
        } else {
            lines.append(.init(speaker: speaker, text: text))
        }
    }
}

// MARK: - Root

/// Wiring only: the controllers above, the three screens, and the sheets that
/// must be reachable from anywhere (the pairing confirmation in particular).
struct ContentView: View {
    @StateObject private var controller = LiveSessionController()
    @StateObject private var pairing = PairingController()
    @StateObject private var runs = RunsController()
    @Environment(\.scenePhase) private var scenePhase

    @State private var apiKey: String = KeychainStore.loadKey() ?? ""
    @State private var keySaved: Bool = KeychainStore.loadKey() != nil
    /// Developer fallback only. A paired session's voice is baked into the
    /// token by the Mac, so the phone has no say and does not pretend to.
    @State private var voice: String = "Iapetus"

    @State private var showSettings = false
    @State private var showRuns = false

    /// DEBUG-only fake state for screenshots and previews. Always nil in a
    /// release build; never reaches a controller.
    private let fixture = PreviewFixture.fromLaunchArguments()

    var body: some View {
        NavigationStack {
            MainView(
                session: controller,
                pairing: pairing,
                runs: runs,
                hasDeveloperKey: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onToggleSession: toggleSession,
                onOpenSettings: { showSettings = true },
                onOpenRuns: { showRuns = true },
                fixture: fixture
            )
        }
        .onOpenURL { url in
            pairing.handle(url: url)
        }
        .onAppear {
            #if DEBUG
            if let fixture { pairing._previewSeed(desktopName: fixture.pairedName) }
            switch PreviewFixture.screenFromLaunchArguments() {
            case "settings": showSettings = true
            case "runs": showRuns = true
            default: break
            }
            #endif
            // `pairing` is the StateObject SwiftUI owns; the session
            // controller holds no reference back, so there is no cycle.
            controller.onLinkError = { [pairing] error in
                pairing.handle(linkError: error)
            }
            runs.onLinkError = { [pairing] error in
                pairing.handle(linkError: error)
            }
            // A completion Iris just spoke should not also buzz.
            controller.onRunAnnounced = { [runs] runId in
                runs.notifier.markHandled(runId)
            }
            runs.configure(paired: pairing.paired)
            Task {
                await pairing.refreshStatus()
                await runs.refresh(notifying: true)
                if !controller.isRunning { runs.startPolling() }
            }
        }
        .onChange(of: pairing.paired) { _, paired in
            runs.configure(paired: paired)
            if paired == nil { runs.stopPolling() } else { runs.startPolling() }
        }
        .onChange(of: controller.runs) { _, list in
            // The live session already polled; keep one list, not two.
            if !list.isEmpty { runs.adopt(list) }
        }
        .onChange(of: controller.isRunning) { _, running in
            // The session's own 2 s poll replaces the quiet background watch.
            if running { runs.stopPolling() } else { runs.startPolling() }
            if running { BackgroundSession.begin { controller.stop() } } else { BackgroundSession.end() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, pairing.paired != nil else { return }
            Task { await runs.refresh(notifying: true) }
        }
        .onChange(of: runs.notifier.openRunId) { _, runId in
            guard let runId, !runId.isEmpty else { return }
            runs.notifier.openRunId = nil
            Task { await runs.read(runId) }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                pairing: pairing,
                session: controller,
                runs: runs,
                apiKey: $apiKey,
                keySaved: $keySaved,
                voice: $voice
            )
        }
        .sheet(isPresented: $showRuns) {
            RunsScreen(
                controller: runs,
                announcingRunId: controller.announcingRunId,
                injectedRuns: fixture?.runs
            )
        }
        // Only when Runs is closed (e.g. opened from a notification). While the
        // Runs sheet is up it presents the result itself.
        .sheet(item: Binding(
            get: { showRuns ? nil : runs.openResult },
            set: { if !showRuns { runs.openResult = $0 } }
        )) { result in
            RunResultView(sheet: result)
        }
        // Must work from anywhere in the app, including over Settings or Runs.
        .sheet(item: $pairing.pendingOffer) { offer in
            PairingSheet(offer: offer, pairing: pairing)
        }
    }

    private func toggleSession() {
        if controller.isRunning {
            controller.stop()
        } else {
            startSession()
        }
    }

    private func startSession() {
        if let paired = pairing.paired {
            // Notifications only start mattering once this phone has work in
            // flight, so this is where they are asked for.
            Task { await runs.notifier.requestPermissionIfNeeded() }
            controller.startWithLink(
                paired: paired,
                model: pairing.status?.liveModel ?? ""
            )
        } else {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { keySaved = KeychainStore.saveKey(trimmed) }
            controller.start(apiKey: apiKey, voice: voice)
        }
    }
}

#if DEBUG
extension PairingController {
    /// Screenshot/preview dressing only, compiled out of release. It writes a
    /// placeholder record straight to the published property and never touches
    /// the Keychain, the Link client or any session path.
    func _previewSeed(desktopName: String?) {
        guard let desktopName, paired == nil else { return }
        paired = PairedDesktop(
            host: "100.101.102.103",
            port: 8765,
            deviceId: "preview",
            credential: "",
            desktopName: desktopName
        )
    }
}
#endif

#Preview("Main — unpaired") {
    ContentView()
}
