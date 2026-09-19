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
        /// The socket is being replaced under a conversation that is still
        /// going. Not an error, and not a dead end.
        case reconnecting = "Reconnecting…"
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
    /// The developer fallback's one-shot start. A paired session uses
    /// `sessionLoop` instead.
    private var starter: Task<Void, Never>?
    private let audio = AudioEngine()

    // MARK: Reconnect state
    //
    // A paired session outlives any one socket. The loop in
    // `runLinkedSessionLoop` owns connecting, and `ReconnectPolicy` owns the
    // decision of whether and when to connect again.

    /// The whole paired session, across every socket it uses.
    private var sessionLoop: Task<Void, Never>?
    private var policy = ReconnectPolicy()
    /// The newest resumable handle the server offered. Never logged, never
    /// shown: it is a key to the conversation.
    private var resumeHandle: String?
    /// Set while we are deliberately dropping a socket to get ahead of the
    /// server's own hang-up, so the loop does not treat it as a failure.
    private var swapRequested = false
    private var goAwayTimer: Task<Void, Never>?
    private var sawSetupComplete = false
    private var socketReady = false
    private var micStarted = false
    /// The last raw socket message. Held back while a reconnect is in play and
    /// only promoted to the banner if reconnecting ultimately fails.
    private var lastTransportError = ""

    /// Mic audio captured while no socket is up. Bounded to ~1.5 s: enough to
    /// carry a syllable across a sub-second swap, short enough that nothing
    /// stale is ever replayed into the server's voice detection.
    private var micBuffer: [Data] = []
    private static let maxBufferedMicBytes = 16_000 * 2 * 3 / 2

    /// Only a paired session can reconnect: a reconnect needs a new token, and
    /// only the Mac can mint one.
    private var reconnectsEnabled: Bool { pairedDesktop != nil }
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
        policy = ReconnectPolicy()
        resumeHandle = nil
        sessionLoop = Task { [weak self] in
            await self?.runLinkedSessionLoop(paired: paired, model: model)
        }
    }

    /// One paired conversation, however many sockets it takes.
    ///
    /// Each pass mints a token, opens a connection, and pumps it until it
    /// ends. What happens next is `ReconnectPolicy`'s call, made from what the
    /// socket actually reported rather than from what closed it.
    private func runLinkedSessionLoop(paired: PairedDesktop, model: String) async {
        var connectionIndex = 0
        var pendingDelay: TimeInterval = 0

        while isRunning && !Task.isCancelled {
            if pendingDelay > 0 {
                status = .reconnecting
                try? await Task.sleep(nanoseconds: UInt64(pendingDelay * 1_000_000_000))
                pendingDelay = 0
                guard isRunning, !Task.isCancelled else { return }
            }

            connectionIndex += 1
            let reconnecting = connectionIndex > 1
            status = reconnecting ? .reconnecting : .authorizing

            // ---- a fresh single-use token, carrying the handle if we have one ----
            let minted: LinkToken
            do {
                minted = try await LinkClient(paired: paired).geminiToken(resumeHandle: resumeHandle)
            } catch {
                let linkError = error as? LinkError
                // `not_paired` ends the session exactly as it always has: the
                // credential is gone and no amount of retrying brings it back.
                if linkError?.clearsPairing == true {
                    finish(error: linkError?.message ?? "This phone is no longer paired.")
                    linkError.map { onLinkError?($0) }
                    return
                }
                guard reconnecting else {
                    finish(error: linkError?.message ?? "Could not get a session token from your Mac.")
                    if let linkError { onLinkError?(linkError) }
                    return
                }
                // Mid-session the Mac being briefly unreachable is just
                // another dropped connection; it gets the same backoff.
                switch policy.decide(
                    cause: .transportDropped(code: 0, reason: "token mint failed"),
                    lived: 0
                ) {
                case .reconnect(let after, let dropHandle):
                    if dropHandle { resumeHandle = nil }
                    note("your Mac did not hand out a session token — trying again in \(Self.seconds(after))")
                    pendingDelay = after
                    continue
                default:
                    finish(error: ReconnectPolicy.giveUpMessage)
                    return
                }
            }
            guard isRunning, !Task.isCancelled else { return }

            // The Mac is the only one that can put the handle in the token, so
            // it is also the only one that can say whether the conversation is
            // actually coming back. Never inferred from having asked.
            let resumed = minted.resumed
            if resumeHandle != nil && !resumed {
                note("the previous conversation could not be restored — starting a fresh one")
                resumeHandle = nil
            }

            let client = LiveClient(config: .init(
                credential: .ephemeralToken(minted.token),
                model: minted.model.isEmpty
                    ? (model.isEmpty ? "models/gemini-3.1-flash-live-preview" : model)
                    : minted.model,
                minimalSetup: true
            ))
            self.client = client
            policy.connectionOpened(resuming: resumed)

            if let coordinator {
                // Same conversation, new pipe: run tracking, the announcement
                // queue and the acknowledged ledger all carry over.
                await coordinator.reattach(transport: client, resumed: resumed)
            } else {
                let sink: @Sendable (CoordinatorEvent) -> Void = { [weak self] event in
                    Task { @MainActor in self?.apply(coordinatorEvent: event) }
                }
                coordinator = SessionCoordinator(
                    link: LinkClient(paired: paired),
                    transport: client,
                    userName: "the user",
                    notify: sink
                )
                startStatusPolling()
            }

            // ---- pump this connection until it ends ----
            status = .connecting
            sawSetupComplete = false
            socketReady = false
            var closeCode = 0
            var closeReason: String?
            var refusal: (code: Int, reason: String?)?
            let openedAt = Date()

            let stream = await client.events()
            await client.connect()
            for await event in stream {
                await apply(event)
                switch event {
                case .authorizationFailed(let code, let reason): refusal = (code, reason)
                case .closed(let code, let reason): closeCode = code; closeReason = reason
                default: break
                }
            }

            goAwayTimer?.cancel()
            goAwayTimer = nil
            socketReady = false
            let lived = Date().timeIntervalSince(openedAt)
            guard isRunning, !Task.isCancelled else { return }

            // We closed it ourselves, ahead of the server's deadline.
            if swapRequested {
                swapRequested = false
                continue
            }

            let cause: LiveCloseCause = refusal.map {
                .authorizationRefused(code: $0.code, reason: $0.reason)
            } ?? ReconnectPolicy.classify(
                code: closeCode,
                reason: closeReason,
                sawSetupComplete: sawSetupComplete,
                lived: lived
            )

            switch policy.decide(cause: cause, lived: lived) {
            case .stopIntentional:
                finish(error: "")
                return
            case .stopAuthorizationFailed(let code, let reason):
                finish(error: "Gemini refused this session's token (close \(code)"
                    + (reason.map { ": \($0)" } ?? "")
                    + "). Tap the orb to ask your Mac for a fresh one.")
                return
            case .giveUp(let message):
                finish(error: message)
                return
            case .reconnect(let after, let dropHandle):
                if dropHandle {
                    note("Gemini would not take us back into that conversation — the next connection starts a fresh one")
                    resumeHandle = nil
                }
                if case .credentialExpired = cause {
                    note("the session token reached its 30-minute expiry — getting a new one")
                }
                await coordinator?.suspend()
                status = .reconnecting
                pendingDelay = after
            }
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value < 1 ? "half a second" : "\(Int(value.rounded())) s"
    }

    /// A line for the debug log. Never the banner: while a reconnect is in
    /// play the user sees "Reconnecting…" and nothing alarming.
    private func note(_ line: String) {
        toolLog.append(line)
        if toolLog.count > 200 { toolLog.removeFirst(toolLog.count - 200) }
    }

    /// The session is over for good. This is the only place a transport
    /// problem becomes something the user is shown.
    private func finish(error: String) {
        let message = error.isEmpty ? lastTransportError : error
        if !message.isEmpty { errorText = message }
        isRunning = false
        status = .closed
        goAwayTimer?.cancel()
        goAwayTimer = nil
        statusPoll?.cancel()
        statusPoll = nil
        audio.stop()
        audioStatus = audio.currentStatus()
        micStarted = false
        micBuffer.removeAll()
        socketReady = false
        resumeHandle = nil
        let coordinator = self.coordinator
        self.coordinator = nil
        Task { await coordinator?.close() }
        client = nil
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
        lastTransportError = ""
        micBuffer.removeAll()
        micStarted = false
        socketReady = false
        sawSetupComplete = false
        swapRequested = false
    }

    /// Developer fallback only. One socket, no reconnect: there is nothing to
    /// mint a second token from, and a pasted key is not a paired session.
    private func begin(credential: LiveClient.Credential, model: String?, voice: String) {
        status = .connecting
        startStatusPolling()

        let instruction = "You are a terse voice assistant. Answer in one or two short sentences unless asked for more."
        let config: LiveClient.Config
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
        let client = LiveClient(config: config)
        self.client = client
        coordinator = nil

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
        goAwayTimer?.cancel()
        goAwayTimer = nil
        sessionLoop?.cancel()
        sessionLoop = nil
        statusPoll?.cancel()
        statusPoll = nil
        audio.stop()
        audioStatus = audio.currentStatus()
        micStarted = false
        micBuffer.removeAll()
        socketReady = false
        resumeHandle = nil
        let coordinator = self.coordinator
        self.coordinator = nil
        Task { await coordinator?.close() }
        let client = self.client
        self.client = nil
        pump?.cancel()
        pump = nil
        // Closing finishes the event stream, which is what lets the session
        // loop above notice that `isRunning` is false and return.
        Task { await client?.close() }
        status = .closed
    }

    // MARK: Proactive reconnect

    /// `goAway` is the server saying how long this socket has left. Rather
    /// than wait to be hung up on mid-sentence, swap the connection while the
    /// line is quiet — the conversation itself continues on the new one.
    private func scheduleProactiveReconnect(timeLeft: TimeInterval?) {
        guard reconnectsEnabled else { return }
        goAwayTimer?.cancel()
        let schedule = ReconnectPolicy.schedule(goAwayTimeLeft: timeLeft, now: Date())
        goAwayTimer = Task { [weak self] in
            let initial = schedule.delay(from: Date())
            if initial > 0 {
                try? await Task.sleep(nanoseconds: UInt64(initial * 1_000_000_000))
            }
            // Don't cut anybody off. Wait for the turn to end — but only until
            // the server's own deadline, because past that it closes the
            // socket whether the sentence finished or not.
            while !Task.isCancelled {
                guard let self, self.isRunning, let coordinator = self.coordinator else { return }
                let busy = await coordinator.isMidTurn()
                guard ReconnectPolicy.shouldWaitForQuiet(
                    busy: busy, now: Date(), hardDeadline: schedule.hardDeadline
                ) else { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled, let self, self.isRunning else { return }
            await self.swapConnection()
        }
    }

    private func swapConnection() async {
        guard isRunning, let client else { return }
        swapRequested = true
        status = .reconnecting
        note("rotating the connection ahead of the server's deadline")
        await coordinator?.suspend()
        // Finishes the event stream; the session loop opens the next socket.
        await client.close()
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
            sawSetupComplete = true
            socketReady = true
            lastTransportError = ""
            // The engine is started once and kept running across every
            // reconnect: restarting it is what would make the swap audible.
            await startMicrophoneIfNeeded()
            flushBufferedMic()

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
            // A completed turn proves this connection works, which is what
            // refills the reconnect budget — same signal the desktop uses.
            policy.connectionHealthy()
            lines.append(.init(speaker: "—", text: "[turn complete]"))

        case .goAway(let timeLeft):
            // NOT an error. The server rotates a Live connection on a fixed
            // lifetime; this is the warning, and the answer is to reconnect,
            // not to end the conversation.
            let seconds = LiveDuration.seconds(timeLeft)
            note("Gemini is rotating this connection (\(timeLeft ?? "soon")) — moving to a new one")
            scheduleProactiveReconnect(timeLeft: seconds)

        case .sessionResumption(let handle, let resumable):
            // The only thing that can bring this conversation back. Kept in
            // memory, never logged, never shown.
            guard resumable, let handle, !handle.isEmpty else { break }
            resumeHandle = handle

        case .toolCall(let calls):
            // Execution belongs to the coordinator; the UI only shows it.
            for call in calls { toolLog.append("↳ \(call.name)") }

        case .toolCallCancellation(let ids):
            toolLog.append("↳ cancelled \(ids.count) tool call(s)")

        case .authorizationFailed(let code, let reason):
            // Not a network error and not something to retry: the token was
            // refused. In a paired session the loop owns what that means, so
            // nothing is put in front of the user from here.
            let text = "Gemini refused this session's token (close \(code)"
                + (reason.map { ": \($0)" } ?? "")
                + "). Tap Start to ask your Mac for a fresh one."
            if reconnectsEnabled { lastTransportError = text; note(text) } else { errorText = text }

        case .error(let message):
            if reconnectsEnabled { lastTransportError = message; note(message) } else { errorText = message }

        case .closed(let code, let reason):
            socketReady = false
            guard !reconnectsEnabled else {
                // The socket is finished; the session may not be. Whether to
                // reconnect is the session loop's decision, not this one's.
                note("connection closed (code \(code))" + (reason.map { ": \($0)" } ?? ""))
                break
            }
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

    /// Started once per session and deliberately NOT restarted on a
    /// reconnect: tearing the audio graph down and back up is what would turn
    /// a socket swap into an audible gap.
    private func startMicrophoneIfNeeded() async {
        guard !micStarted else { return }
        let granted = await audio.requestMicrophonePermission()
        guard granted else {
            errorText = "Microphone permission denied."
            return
        }
        micStarted = true
        audio.onError = { [weak self] message in
            Task { @MainActor in self?.errorText = message }
        }
        audio.onCapturedChunk = { [weak self] chunk in
            Task { @MainActor in self?.sendOrBuffer(mic: chunk) }
        }
        audio.start()
    }

    /// Mic audio has nowhere to go between sockets. Rather than drop the
    /// user's words outright, hold a bounded tail of them and deliver it once
    /// the new session is up. The bound matters: replaying seconds of stale
    /// audio would land as an utterance the user never made.
    private func sendOrBuffer(mic chunk: Data) {
        guard socketReady, let client else {
            micBuffer.append(chunk)
            var buffered = micBuffer.reduce(0) { $0 + $1.count }
            while buffered > Self.maxBufferedMicBytes, !micBuffer.isEmpty {
                buffered -= micBuffer.removeFirst().count
            }
            return
        }
        Task { await client.sendAudio(chunk) }
    }

    private func flushBufferedMic() {
        guard let client, !micBuffer.isEmpty else { micBuffer.removeAll(); return }
        let pending = micBuffer
        micBuffer.removeAll()
        note("carried \(pending.count) mic chunk(s) across the reconnect")
        Task {
            for chunk in pending { await client.sendAudio(chunk) }
        }
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
