//
//  LiveClient.swift
//  IrisLivePrototype
//
//  A dependency-free client for the Gemini Live API (BidiGenerateContent)
//  built directly on URLSessionWebSocketTask. Foundation only, so the exact
//  same file compiles for iOS and for the macOS command-line probe in Tools/.
//
//  Protocol reference:
//    https://ai.google.dev/api/live
//    https://ai.google.dev/gemini-api/docs/live-guide
//
//  Wire format notes that matter:
//    - JSON field names are camelCase over the socket.
//    - The server may deliver JSON in *binary* frames, so both .string and
//      .data have to be decoded as UTF-8 JSON.
//    - Input audio is raw PCM16 little-endian mono at 16 kHz, base64'd, with
//      mimeType "audio/pcm;rate=16000".
//    - Output audio is raw PCM16 little-endian mono at 24 kHz.
//

import Foundation

// MARK: - Events

public enum LiveEvent: Sendable {
    /// The socket opened and the setup frame was written.
    case opened
    /// Server acknowledged `setup`. Safe to start streaming audio now.
    case setupComplete
    /// PCM16 mono 24 kHz audio from the model (already base64-decoded).
    case audio(Data)
    /// Incremental transcription of what the *user* said.
    case inputTranscript(String)
    /// Incremental transcription of what the *model* said.
    case outputTranscript(String)
    /// A text part inside modelTurn (rare when responseModalities is AUDIO).
    case text(String)
    /// Barge-in: the model's generation was cancelled. Flush playback NOW.
    case interrupted
    /// Model finished generating for this turn.
    case generationComplete
    /// Turn boundary.
    case turnComplete
    /// Server intends to close the connection soon.
    case goAway(String?)
    /// Session resumption handle update (not used by the prototype, surfaced anyway).
    case sessionResumption(handle: String?, resumable: Bool)
    /// Non-fatal or fatal error text.
    case error(String)
    /// Socket closed. `code` is the URLSessionWebSocketTask close code raw value.
    case closed(code: Int, reason: String?)
}

// MARK: - Client

public actor LiveClient {

    public struct Config: Sendable {
        public var apiKey: String
        public var model: String
        public var voiceName: String
        public var systemInstruction: String?
        public var enableTranscription: Bool

        public init(
            apiKey: String,
            model: String = "models/gemini-3.1-flash-live-preview",
            voiceName: String = "Iapetus",
            systemInstruction: String? = nil,
            enableTranscription: Bool = true
        ) {
            self.apiKey = apiKey
            self.model = model
            self.voiceName = voiceName
            self.systemInstruction = systemInstruction
            self.enableTranscription = enableTranscription
        }
    }

    public enum State: Sendable {
        case idle, connecting, ready, closed
    }

    private static let endpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private let config: Config
    private var urlSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<LiveEvent>.Continuation?
    private(set) public var state: State = .idle

    public init(config: Config) {
        self.config = config
    }

    /// Creates (or replaces) the event stream. Call before `connect()`.
    public func events() -> AsyncStream<LiveEvent> {
        AsyncStream(LiveEvent.self, bufferingPolicy: .unbounded) { cont in
            self.continuation = cont
        }
    }

    // MARK: Connect / close

    public func connect() async {
        guard socket == nil else { return }
        state = .connecting

        guard var comps = URLComponents(string: Self.endpoint) else {
            emit(.error("Bad endpoint URL"))
            return
        }
        // The key travels as a query parameter; never log the resulting URL.
        comps.queryItems = [URLQueryItem(name: "key", value: config.apiKey)]
        guard let url = comps.url else {
            emit(.error("Could not build endpoint URL"))
            return
        }

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = false
        sessionConfig.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: sessionConfig)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024

        urlSession = session
        socket = task
        task.resume()

        emit(.opened)
        startReceiveLoop()
        await sendSetup()
    }

    public func close() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        if state != .closed {
            state = .closed
            emit(.closed(code: URLSessionWebSocketTask.CloseCode.goingAway.rawValue, reason: "client closed"))
        }
        continuation?.finish()
        continuation = nil
    }

    // MARK: Outbound frames

    private func sendSetup() async {
        var generationConfig: [String: Any] = [
            "responseModalities": ["AUDIO"],
            "speechConfig": [
                "voiceConfig": [
                    "prebuiltVoiceConfig": ["voiceName": config.voiceName]
                ]
            ]
        ]
        // Keep the prototype's replies short so a 30 s test is easy to run.
        generationConfig["temperature"] = 0.8

        var setup: [String: Any] = [
            "model": config.model,
            "generationConfig": generationConfig
        ]
        if config.enableTranscription {
            setup["inputAudioTranscription"] = [String: Any]()
            setup["outputAudioTranscription"] = [String: Any]()
        }
        if let instruction = config.systemInstruction, !instruction.isEmpty {
            setup["systemInstruction"] = ["parts": [["text": instruction]]]
        }
        await sendJSON(["setup": setup])
    }

    /// Streams a chunk of microphone audio. `pcm16` is little-endian mono 16 kHz.
    public func sendAudio(_ pcm16: Data) async {
        guard !pcm16.isEmpty else { return }
        await sendJSON([
            "realtimeInput": [
                "audio": [
                    "data": pcm16.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ])
    }

    /// Tells the server the user's audio stream ended (manual end-of-speech).
    public func sendAudioStreamEnd() async {
        await sendJSON(["realtimeInput": ["audioStreamEnd": true]])
    }

    /// Injects text into the live conversation as a realtimeInput text part.
    public func sendRealtimeText(_ text: String) async {
        await sendJSON(["realtimeInput": ["text": text]])
    }

    /// Sends a complete user turn via clientContent.
    public func sendTextTurn(_ text: String, turnComplete: Bool = true) async {
        await sendJSON([
            "clientContent": [
                "turns": [["role": "user", "parts": [["text": text]]]],
                "turnComplete": turnComplete
            ]
        ])
    }

    private func sendJSON(_ object: [String: Any]) async {
        guard let socket else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            emit(.error("Failed to encode outbound message"))
            return
        }
        do {
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            emit(.error("Send failed: \(error.localizedDescription)"))
        }
    }

    // MARK: Inbound frames

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let socket = await self.currentSocket else { return }
                do {
                    let message = try await socket.receive()
                    await self.handle(message)
                } catch {
                    await self.handleReceiveFailure(error)
                    return
                }
            }
        }
    }

    private var currentSocket: URLSessionWebSocketTask? { socket }

    private func handleReceiveFailure(_ error: Error) {
        guard state != .closed else { return }
        let code = socket?.closeCode.rawValue ?? 0
        let reason = socket?.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        state = .closed
        // A clean server-side close surfaces here as an error too; report both.
        emit(.error("Socket receive ended: \(error.localizedDescription)"))
        emit(.closed(code: code, reason: reason))
        continuation?.finish()
        continuation = nil
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let payload):
            data = payload
        @unknown default:
            return
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            emit(.error("Unparsable frame (\(data.count) bytes)"))
            return
        }
        route(root)
    }

    private func route(_ root: [String: Any]) {
        if root["setupComplete"] != nil {
            state = .ready
            emit(.setupComplete)
        }

        if let goAway = root["goAway"] as? [String: Any] {
            emit(.goAway(goAway["timeLeft"] as? String))
        }

        if let resumption = root["sessionResumptionUpdate"] as? [String: Any] {
            emit(.sessionResumption(
                handle: resumption["newHandle"] as? String,
                resumable: (resumption["resumable"] as? Bool) ?? false
            ))
        }

        guard let content = root["serverContent"] as? [String: Any] else { return }

        if let transcription = content["inputTranscription"] as? [String: Any],
           let text = transcription["text"] as? String, !text.isEmpty {
            emit(.inputTranscript(text))
        }

        // Barge-in. The Electron reference returns immediately here; nothing
        // else in this frame is meaningful once the turn is cancelled.
        if (content["interrupted"] as? Bool) == true {
            emit(.interrupted)
            return
        }

        if let transcription = content["outputTranscription"] as? [String: Any],
           let text = transcription["text"] as? String, !text.isEmpty {
            emit(.outputTranscript(text))
        }

        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                if let text = part["text"] as? String, !text.isEmpty {
                    emit(.text(text))
                }
                guard let inline = part["inlineData"] as? [String: Any],
                      let base64 = inline["data"] as? String
                else { continue }
                let mime = (inline["mimeType"] as? String) ?? "audio/pcm;rate=24000"
                guard mime.hasPrefix("audio/") else { continue }
                if let pcm = Data(base64Encoded: base64), !pcm.isEmpty {
                    emit(.audio(pcm))
                }
            }
        }

        if (content["generationComplete"] as? Bool) == true {
            emit(.generationComplete)
        }
        if (content["turnComplete"] as? Bool) == true {
            emit(.turnComplete)
        }
    }

    private func emit(_ event: LiveEvent) {
        continuation?.yield(event)
    }
}
