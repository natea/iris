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
    /// The model wants one or more declared functions executed. Field names
    /// per https://ai.google.dev/api/live: `toolCall.functionCalls[]`, each
    /// with `id`, `name`, `args`.
    case toolCall([LiveToolCall])
    /// `toolCallCancellation.ids[]` — the model abandoned these calls. Their
    /// results must not be sent, and a cancelled side effect must not happen.
    case toolCallCancellation([String])
    /// Turn boundary.
    case turnComplete
    /// Server intends to close the connection soon.
    case goAway(String?)
    /// Session resumption handle update (not used by the prototype, surfaced anyway).
    case sessionResumption(handle: String?, resumable: Bool)
    /// Non-fatal or fatal error text.
    case error(String)
    /// The server refused our credential. Verified behaviour: an ephemeral
    /// token that is expired, already used, or outside its start window is not
    /// rejected at the handshake — the socket opens and is then closed with
    /// code 1011 and a reason string. This is an authorization failure, never a
    /// network blip, and must never be blindly retried.
    case authorizationFailed(code: Int, reason: String?)
    /// Socket closed. `code` is the URLSessionWebSocketTask close code raw value.
    case closed(code: Int, reason: String?)
}

// MARK: - Tool calls

/// One entry of `toolCall.functionCalls[]`.
///
/// `args` is decoded JSON, so it is `[String: Any]`; the struct is
/// `@unchecked Sendable` because that dictionary is created once at parse time
/// and never mutated afterwards.
public struct LiveToolCall: @unchecked Sendable {
    /// The call id the matching function response must echo back.
    public let id: String
    public let name: String
    public let args: [String: Any]

    public init(id: String, name: String, args: [String: Any]) {
        self.id = id
        self.name = name
        self.args = args
    }

    public init?(json: [String: Any]) {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        self.id = (json["id"] as? String) ?? ""
        self.name = name
        self.args = (json["args"] as? [String: Any]) ?? [:]
    }

    /// Models sometimes send a number or a bool where a string is declared;
    /// coerce rather than silently dropping the user's detail.
    public func string(_ key: String) -> String {
        switch args[key] {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        case .none: return ""
        case .some(let value): return String(describing: value)
        }
    }

    public func stringArray(_ key: String) -> [String] {
        if let values = args[key] as? [Any] {
            return values.compactMap { item in
                if let text = item as? String { return text }
                if let number = item as? NSNumber { return number.stringValue }
                return nil
            }
        }
        if let single = args[key] as? String { return [single] }
        return []
    }
}

/// One entry of `toolResponse.functionResponses[]`.
public struct LiveFunctionResponse: @unchecked Sendable {
    public let id: String
    public let name: String
    public let response: [String: Any]

    public init(id: String, name: String, response: [String: Any]) {
        self.id = id
        self.name = name
        self.response = response
    }

    var wireFormat: [String: Any] {
        var entry: [String: Any] = ["name": name, "response": response]
        // The id is optional on the wire but required for correlation when the
        // model issues several calls in one turn.
        if !id.isEmpty { entry["id"] = id }
        return entry
    }
}

/// What the session coordinator needs from a live socket. A protocol so the
/// coordinator can be driven by something other than a real connection.
public protocol LiveTransport: Sendable {
    func sendToolResponses(_ responses: [LiveFunctionResponse]) async
    func sendTextTurn(_ text: String, turnComplete: Bool) async
}

// MARK: - Client

public actor LiveClient: LiveTransport {

    /// How this session authenticates. The two modes reach *different*
    /// endpoints — see `endpoint(for:)`.
    public enum Credential: Sendable {
        /// A long-lived Gemini API key. On the phone this is the developer
        /// fallback only; a paired phone never holds one.
        case apiKey(String)
        /// An ephemeral token (`auth_tokens/…`) minted by the Iris desktop.
        case ephemeralToken(String)

        var value: String {
            switch self {
            case .apiKey(let key): return key
            case .ephemeralToken(let token): return token
            }
        }
    }

    public struct Config: Sendable {
        public var credential: Credential
        public var model: String
        public var voiceName: String
        public var systemInstruction: String?
        public var enableTranscription: Bool
        /// Paired mode. An ephemeral token carries
        /// `liveConnectConstraints.config`, which REPLACES the client's setup
        /// frame: voice, transcription, system instruction and tool
        /// declarations all come from the Mac. So the phone sends the bare
        /// minimum needed to open the session and relies on none of it
        /// (LINK_API.md §3).
        public var minimalSetup: Bool

        public init(
            credential: Credential,
            model: String = "models/gemini-3.1-flash-live-preview",
            voiceName: String = "Iapetus",
            systemInstruction: String? = nil,
            enableTranscription: Bool = true,
            minimalSetup: Bool = false
        ) {
            self.credential = credential
            self.model = model
            self.voiceName = voiceName
            self.systemInstruction = systemInstruction
            self.enableTranscription = enableTranscription
            self.minimalSetup = minimalSetup
        }

        public init(
            apiKey: String,
            model: String = "models/gemini-3.1-flash-live-preview",
            voiceName: String = "Iapetus",
            systemInstruction: String? = nil,
            enableTranscription: Bool = true
        ) {
            self.init(
                credential: .apiKey(apiKey),
                model: model,
                voiceName: voiceName,
                systemInstruction: systemInstruction,
                enableTranscription: enableTranscription,
                minimalSetup: false
            )
        }
    }

    public enum State: Sendable {
        case idle, connecting, ready, closed
    }

    private static let host = "wss://generativelanguage.googleapis.com"

    /// An API key and an ephemeral token are NOT interchangeable on this
    /// socket. Read out of `@google/genai` (dist/index.mjs, Live.connect):
    /// a credential beginning `auth_tokens/` switches the RPC to
    /// `BidiGenerateContentConstrained`, the API version to `v1alpha`, and the
    /// query parameter from `key` to `access_token`. The "constrained" half of
    /// the name is the token's `liveConnectConstraints` — the model and
    /// response modalities were fixed when the desktop minted it.
    static func endpoint(for credential: Credential) -> (url: String, parameter: String, value: String) {
        switch credential {
        case .apiKey(let key):
            return (
                "\(host)/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent",
                "key",
                key
            )
        case .ephemeralToken(let token):
            return (
                "\(host)/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained",
                "access_token",
                token
            )
        }
    }

    /// A server-side close this soon after opening is a refused credential
    /// dressed up as a connection, not a network problem.
    private static let authorizationCloseWindow: TimeInterval = 2.0

    private let config: Config
    private var urlSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<LiveEvent>.Continuation?
    private var openedAt: Date?
    private var sawSetupComplete = false
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

        let route = Self.endpoint(for: config.credential)
        guard var comps = URLComponents(string: route.url) else {
            emit(.error("Bad endpoint URL"))
            return
        }
        // The credential travels as a query parameter; never log the URL.
        comps.queryItems = [URLQueryItem(name: route.parameter, value: route.value)]
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
        openedAt = Date()
        sawSetupComplete = false
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
        if config.minimalSetup {
            // Everything else is supplied by the token and silently ignored
            // here; sending it anyway would only invite the illusion that the
            // phone controls it.
            await sendJSON(["setup": ["model": config.model]])
            return
        }
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

    /// Answers one or more tool calls. Wire shape per
    /// https://ai.google.dev/api/live —
    /// `{"toolResponse": {"functionResponses": [{"id", "name", "response"}]}}`.
    public func sendToolResponses(_ responses: [LiveFunctionResponse]) async {
        guard !responses.isEmpty else { return }
        await sendJSON(["toolResponse": ["functionResponses": responses.map(\.wireFormat)]])
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
        let elapsed = openedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        state = .closed
        if isAuthorizationClose(code: code, elapsed: elapsed) {
            emit(.authorizationFailed(code: code, reason: reason))
        } else {
            // A clean server-side close surfaces here as an error too; report both.
            emit(.error("Socket receive ended: \(error.localizedDescription)"))
        }
        emit(.closed(code: code, reason: reason))
        continuation?.finish()
        continuation = nil
    }

    /// 1011 at any point, or *any* server close before the session ever became
    /// usable, is the shape a refused token takes on this API.
    private func isAuthorizationClose(code: Int, elapsed: TimeInterval) -> Bool {
        if code == 1011 { return true }
        if !sawSetupComplete && elapsed <= Self.authorizationCloseWindow { return true }
        return false
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
            sawSetupComplete = true
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

        // Tool traffic is a sibling of serverContent, not a child of it.
        if let cancellation = root["toolCallCancellation"] as? [String: Any] {
            let ids = (cancellation["ids"] as? [Any])?.compactMap { $0 as? String } ?? []
            if !ids.isEmpty { emit(.toolCallCancellation(ids)) }
        }

        if let toolCall = root["toolCall"] as? [String: Any] {
            let raw = (toolCall["functionCalls"] as? [[String: Any]]) ?? []
            let calls = raw.compactMap(LiveToolCall.init(json:))
            if !calls.isEmpty { emit(.toolCall(calls)) }
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
