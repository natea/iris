//
//  VoicePreviewController.swift
//  IrisLivePrototype
//
//  Hearing a voice before choosing it (LINK_API.md §13.5).
//
//  The flow is short and fixed, and every step of it is the contract's:
//
//    1. mint a token with `{"voice": "<candidate>", "purpose": "preview"}`;
//    2. connect exactly like a real session — v1alpha, token as the API key,
//       EMPTY setup config, because the token's config replaces it here too;
//    3. send one text turn, literally `"Go."`;
//    4. play the audio parts as they arrive;
//    5. close as soon as `serverContent.turnComplete` is seen.
//
//  Nothing else is done with a preview token: it is `uses: 1`, lives two
//  minutes, and carries no tools and no personal context, so there is nothing
//  else it could be used for. It is never stored, never logged, never shown.
//
//  Only one preview runs at a time, and none runs while a real session is
//  live (§13.5) — two Live connections would compete for the same audio.
//

import Foundation

@MainActor
public final class VoicePreviewController: ObservableObject {

    public enum Phase: Equatable {
        case idle
        /// Minting and connecting. The row shows a spinner.
        case connecting(String)
        /// Audio is arriving for this voice.
        case playing(String)

        var voice: String? {
            switch self {
            case .idle: return nil
            case .connecting(let name), .playing(let name): return name
            }
        }
    }

    @Published public private(set) var phase: Phase = .idle
    /// Plain-language failure for the row that failed, shown inline.
    @Published public private(set) var failure: (voice: String, message: String)?
    /// The sample line, captured from `outputAudioTranscription`, so the user
    /// can read what they are hearing. Never invented.
    @Published public private(set) var caption: String = ""

    /// A preview never starts unless this says no session is live. Set by the
    /// root view once the session controller exists; the default refuses
    /// nothing only because there is nothing to refuse yet.
    public var isSessionLive: () -> Bool = { false }

    private var task: Task<Void, Never>?
    #if os(iOS)
    private let audio = VoicePreviewPlayer()
    #endif

    /// Generous, but finite: a preview that never answers has to end by itself
    /// rather than leave a spinner turning.
    private static let deadline: TimeInterval = 25

    public init() {}

    public var isBusy: Bool { phase != .idle }

    public func isBusy(with voice: String) -> Bool { phase.voice == voice }

    // MARK: Play / stop

    /// Tapping ▶ on a row. Tapping it again, or tapping another row, stops
    /// whatever is playing first — there is only ever one preview.
    public func play(voice: String, paired: PairedDesktop) {
        let wasPlaying = phase.voice
        stop()
        guard wasPlaying != voice else { return }
        guard !isSessionLive() else {
            failure = (voice, "Iris is in a conversation right now. End it to hear a different voice.")
            return
        }
        failure = nil
        caption = ""
        phase = .connecting(voice)
        task = Task { [weak self] in
            await self?.run(voice: voice, paired: paired)
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        #if os(iOS)
        audio.stop()
        #endif
        phase = .idle
    }

    // MARK: The connection

    private func run(voice: String, paired: PairedDesktop) async {
        let minted: LinkToken
        do {
            minted = try await LinkClient(paired: paired).geminiToken(voice: voice, purpose: .preview)
        } catch let error as LinkError {
            finish(voice: voice, message: Self.mintMessage(for: error, voice: voice))
            return
        } catch {
            finish(voice: voice, message: "Could not reach Iris on your Mac to hear that voice.")
            return
        }
        guard !Task.isCancelled else { return }

        let client = LiveClient(config: .init(
            credential: .ephemeralToken(minted.token),
            model: minted.model.isEmpty ? "models/gemini-3.1-flash-live-preview" : minted.model,
            // The token's config replaces the setup frame here exactly as it
            // does for a session, so the phone sends the bare minimum.
            minimalSetup: true
        ))

        #if os(iOS)
        audio.onError = { [weak self] message in
            Task { @MainActor in self?.finish(voice: voice, message: message) }
        }
        audio.start()
        #endif

        let stream = await client.events()
        await client.connect()

        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.deadline * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.phase.voice == voice else { return }
                self.finish(voice: voice, message: "That preview did not arrive in time.")
            }
            await client.close()
        }
        defer { watchdog.cancel() }

        var heardAudio = false
        var problem: String?

        for await event in stream {
            if Task.isCancelled { break }
            switch event {
            case .setupComplete:
                // §13.5 step 3 — exactly one turn, and exactly this text.
                await client.sendTextTurn("Go.", turnComplete: true)

            case .audio(let pcm):
                heardAudio = true
                if phase.voice == voice { phase = .playing(voice) }
                #if os(iOS)
                audio.enqueue(pcm)
                #endif

            case .outputTranscript(let text):
                caption += text

            case .turnComplete:
                // The sample is one fixed line; there is nothing after it.
                await client.close()

            case .authorizationFailed:
                problem = "Your Mac's preview token was refused. Try again."

            case .error(let message):
                // Only reported if nothing was ever heard: a close at the end
                // of a finished sample is not a failure.
                if !heardAudio { problem = Self.transportMessage(message) }

            default:
                break
            }
        }

        await client.close()
        guard !Task.isCancelled else { return }

        if !heardAudio {
            finish(voice: voice, message: problem ?? "That voice did not play. Check that Iris is running on your Mac.")
            return
        }
        // Let the tail of the buffered audio actually come out of the speaker
        // before the graph is torn down.
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard !Task.isCancelled else { return }
        #if os(iOS)
        audio.stop()
        #endif
        if phase.voice == voice { phase = .idle }
    }

    private func finish(voice: String, message: String) {
        #if os(iOS)
        audio.stop()
        #endif
        if phase.voice == voice || phase == .idle {
            phase = .idle
            failure = (voice, message)
        }
    }

    static func mintMessage(for error: LinkError, voice: String) -> String {
        switch error {
        case .invalidVoice:
            return "Your Mac does not have a voice called “\(voice)” any more."
        case .invalidPurpose:
            return "Iris on your Mac is too old to preview a voice. Update it on the desktop."
        default:
            return error.message
        }
    }

    static func transportMessage(_ raw: String) -> String {
        raw.isEmpty ? "The preview connection failed." : "The preview connection failed. (\(raw))"
    }
}
