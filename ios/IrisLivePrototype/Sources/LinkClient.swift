//
//  LinkClient.swift
//  IrisLivePrototype
//
//  The phone's client for Iris Link — the small HTTP service the Iris desktop
//  app binds to its Tailscale address. Three things happen here and nowhere
//  else in the app:
//
//    1. Parsing the `iris-link://pair?…` deep link a QR scan delivers, strictly,
//       so a hostile QR cannot point this app at an arbitrary server.
//    2. Deriving the six-digit confirmation code from the pairing secret with
//       the same derivation the desktop uses (electron/pairingStore.mjs), so
//       both ends can show the same number without another round trip.
//    3. Talking to /link/pair, /link/status and /link/gemini-token, and turning
//       a 401 `not_paired` into a distinct error the UI must act on.
//
//  Foundation + CryptoKit only: the exact same file compiles for iOS and for
//  the macOS command-line probe in Tools/.
//
//  Nothing here ever logs a secret, a credential, a token, or a whole URL.
//

import Foundation
import CryptoKit

// MARK: - Pairing offer (what a QR code carries)

/// A validated `iris-link://pair` payload. Holding one of these means the
/// scheme, version, address, port and secret all passed inspection.
public struct PairingOffer: Sendable, Equatable {
    public let host: String
    public let port: Int
    /// One-time pairing secret. Never log this, never render it, never put it
    /// in a URL that anything but Iris Link will see.
    public let secret: String
    public let desktopName: String

    public init(host: String, port: Int, secret: String, desktopName: String) {
        self.host = host
        self.port = port
        self.secret = secret
        self.desktopName = desktopName
    }

    /// The six digits the user compares against the Mac. Derived locally.
    public var code: String { IrisLinkDeepLink.pairingCode(forSecret: secret) }

    public var address: String { "\(host):\(port)" }

    public var baseURL: URL? { URL(string: "http://\(host):\(port)") }

    /// Deliberately hides the secret: this is what any description of an offer
    /// is allowed to say.
    public var debugDescription: String { "PairingOffer(\(address), code \(code))" }
}

public enum PairingLinkError: Error, Equatable {
    case notAnIrisLink
    case notAPairingLink
    case unsupportedVersion(String)
    case missingHost
    case hostNotOnTailnet(String)
    case badPort(String)
    case missingSecret

    public var message: String {
        switch self {
        case .notAnIrisLink, .notAPairingLink:
            return "That link is not an Iris pairing link."
        case .unsupportedVersion(let value):
            return "This pairing code is version \(value); this app understands version 1. Update one of the two."
        case .missingHost:
            return "The pairing link carried no address."
        case .hostNotOnTailnet(let host):
            return "The pairing link points at \(host), which is not a Tailscale address. Iris only pairs over your tailnet, so this code was refused."
        case .badPort(let value):
            return "The pairing link carried an invalid port (\(value))."
        case .missingSecret:
            return "The pairing link carried no pairing secret."
        }
    }
}

public enum IrisLinkDeepLink {

    public static let scheme = "iris-link"

    /// Strict parse of `iris-link://pair?v=1&host=…&port=…&secret=…&name=…`.
    ///
    /// The host must be an IPv4 literal inside Tailscale's 100.64.0.0/10 range.
    /// That single rule is what stops a QR code found in the wild from aiming
    /// the app at an attacker's server and harvesting a pairing attempt.
    ///
    /// - Parameter allowAnyHost: **test-only.** The CLI probe in Tools/ sets it
    ///   so it can drive a server on 127.0.0.1. No code path in the app passes
    ///   anything but the default.
    public static func parse(_ url: URL, allowAnyHost: Bool = false) throws -> PairingOffer {
        guard url.scheme?.lowercased() == scheme else { throw PairingLinkError.notAnIrisLink }

        // `iris-link://pair?…` puts "pair" in `host`; `iris-link:pair?…` puts it
        // in `path`. Accept the first, which is what the desktop emits.
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        guard action == "pair" else { throw PairingLinkError.notAPairingLink }

        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PairingLinkError.notAPairingLink
        }
        var values: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            guard let value = item.value, !value.isEmpty else { continue }
            values[item.name] = value
        }

        let version = values["v"] ?? ""
        guard version == "1" else { throw PairingLinkError.unsupportedVersion(version.isEmpty ? "unset" : version) }

        guard let host = values["host"], !host.isEmpty else { throw PairingLinkError.missingHost }
        if !allowAnyHost && !isTailscaleIPv4(host) { throw PairingLinkError.hostNotOnTailnet(host) }

        let rawPort = values["port"] ?? ""
        guard let port = Int(rawPort), port >= 1, port <= 65_535 else {
            throw PairingLinkError.badPort(rawPort.isEmpty ? "unset" : rawPort)
        }

        guard let secret = values["secret"], !secret.isEmpty else { throw PairingLinkError.missingSecret }

        // The desktop builds the query with URLSearchParams, which encodes a
        // space as "+" (form-urlencoding). URLComponents does not undo that, so
        // "Nate's Mac" would otherwise be shown as "Nate's+Mac". Only the
        // display name is decoded this way: the secret is base64url and never
        // contains "+", and host/port are numeric.
        let name = (values["name"] ?? "")
            .replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PairingOffer(
            host: host,
            port: port,
            secret: secret,
            desktopName: name.isEmpty ? "Iris desktop" : name
        )
    }

    /// True only for a dotted-quad IPv4 literal inside 100.64.0.0/10 — the
    /// CGNAT range Tailscale assigns. 100.64.0.0 … 100.127.255.255.
    public static func isTailscaleIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            // Reject "01", "+1", " 1" and anything non-numeric: an IPv4 literal
            // with leading zeros is parsed as octal by some resolvers.
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            if part.count > 1 && part.first == "0" { return false }
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
            octets.append(value)
        }
        return octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127
    }

    /// Mirrors `pairingCodeFor()` in electron/pairingStore.mjs: the first four
    /// bytes of SHA-256(secret) read big-endian, modulo a million, zero-padded.
    public static func pairingCode(forSecret secret: String) -> String {
        let digest = SHA256.hash(data: Data(secret.utf8))
        var value: UInt32 = 0
        for byte in digest.prefix(4) { value = (value << 8) | UInt32(byte) }
        return String(format: "%06u", value % 1_000_000)
    }
}

// MARK: - Stored pairing

/// What the phone keeps after a successful pairing. The credential is a bearer
/// token for a terminal-capable agent, so it only ever lives in the Keychain.
public struct PairedDesktop: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var deviceId: String
    public var credential: String
    public var desktopName: String

    public init(host: String, port: Int, deviceId: String, credential: String, desktopName: String) {
        self.host = host
        self.port = port
        self.deviceId = deviceId
        self.credential = credential
        self.desktopName = desktopName
    }

    public var address: String { "\(host):\(port)" }
    public var baseURL: URL? { URL(string: "http://\(host):\(port)") }
}

// MARK: - Responses

public struct LinkPairResult: Sendable, Equatable {
    public let deviceId: String
    public let credential: String
    /// The code the desktop believes it showed. Useful as a cross-check only;
    /// the phone derives its own from the secret before the user ever taps Pair.
    public let code: String
}

/// One entry of `GET /link/status` → `voices` (LINK_API.md §13.3). Shown as
/// "Algenib · Gravelly"; the name is the only part the token route accepts.
public struct LinkVoice: Sendable, Equatable, Hashable, Identifiable {
    public let name: String
    public let style: String

    public init(name: String, style: String) {
        self.name = name
        self.style = style
    }

    public init?(json: [String: Any]) {
        guard let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else { return nil }
        self.name = name
        self.style = ((json["style"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
    }

    public var id: String { name }

    /// §13.3 — "<name> · <style>", and just the name when the Mac sent none.
    public var label: String { style.isEmpty ? name : "\(name) · \(style)" }
}

public struct LinkStatus: Sendable, Equatable {
    public let deviceId: String
    public let deviceName: String
    public let hermesReachable: Bool
    public let userName: String
    public let liveModel: String
    public let voice: String
    public let accent: String
    /// §13.3 — the full catalogue the picker is built from. Empty on a desktop
    /// that predates §13, which the picker reports rather than papers over.
    public let voices: [LinkVoice]
    /// §13.3 — what a session token gets when the phone sends no `voice`.
    public let defaultVoice: String
    /// §11 — whether this Mac can push at all. `false` means registering will
    /// succeed and no notification will ever arrive; say so.
    public let pushConfigured: Bool
    /// Which desktop build answered: a short commit (with "+" when the working
    /// tree had uncommitted changes) and when that process started. The Mac's
    /// main process does not hot-reload, so this is how a stale Mac app shows.
    public var macBuild: String = ""
    public var macStartedAtMs: Double = 0

    public init(
        deviceId: String, deviceName: String, hermesReachable: Bool,
        userName: String, liveModel: String, voice: String, accent: String,
        voices: [LinkVoice] = [], defaultVoice: String = "", pushConfigured: Bool = false
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.hermesReachable = hermesReachable
        self.userName = userName
        self.liveModel = liveModel
        self.voice = voice
        self.accent = accent
        self.voices = voices
        self.defaultVoice = defaultVoice
        self.pushConfigured = pushConfigured
    }
}

public struct LinkToken: Sendable, Equatable {
    public let token: String
    public let expiresAt: String?
    public let newSessionExpiresAt: String?
    public let model: String
    /// True only when the desktop confirms it baked the requested resumption
    /// handle into this token's `liveConnectConstraints.config`.
    ///
    /// Absent (and therefore false) on any desktop build that does not
    /// implement `resume_handle`, which is the honest answer: without the
    /// handle in the token, the phone is starting a NEW conversation and has
    /// to say so. It is never inferred from the request having been sent.
    public let resumed: Bool
    /// §13.1 — the voice actually baked into this token (the catalogue's
    /// canonical casing, or the Mac's default when none was asked for). `""`
    /// on a desktop that predates §13.
    public let voice: String
    /// §13.1 — `"session"` or `"preview"`, echoed by the desktop.
    public let purpose: String

    public init(
        token: String,
        expiresAt: String? = nil,
        newSessionExpiresAt: String? = nil,
        model: String = "",
        resumed: Bool = false,
        voice: String = "",
        purpose: String = "session"
    ) {
        self.token = token
        self.expiresAt = expiresAt
        self.newSessionExpiresAt = newSessionExpiresAt
        self.model = model
        self.resumed = resumed
        self.voice = voice
        self.purpose = purpose
    }
}

/// §13.1 — what a token is for. A preview token carries no tools and no
/// personal context, so the two must never be confused at a call site.
public enum LinkTokenPurpose: String, Sendable {
    case session
    case preview
}

// MARK: - Errors

public enum LinkError: Error, Equatable {

    /// 401 `not_paired`. The desktop no longer knows this phone: the stored
    /// credential must be discarded and the UI must say so out loud.
    case notPaired

    /// The desktop could not be reached at all — tailnet down, Mac asleep,
    /// Iris not running. Never conflated with a refusal.
    case unreachable(String)

    /// A pairing offer was refused by the desktop, with its own error code.
    case pairingRefused(String)

    /// The desktop is reachable but could not mint a Gemini token (502).
    case tokenUnavailable

    /// 400 `invalid_voice` (§13.1). The name this phone stored is not in the
    /// Mac's catalogue any more — fall back to the default and say so.
    case invalidVoice
    /// 400 `invalid_purpose` (§13.1). Only reachable if the two ends disagree
    /// about the contract.
    case invalidPurpose
    /// 501 `push_unavailable` — this desktop build has no push-token store.
    case pushUnavailable

    // ----- The task API's named failures (LINK_API.md §4) -----

    /// 501. This desktop build never wired the task API.
    case tasksUnavailable
    /// 404 `task_unknown` — the desktop has never seen this run id.
    case taskUnknown
    /// 409 `task_not_finished` — asked for a result before a terminal status.
    case taskNotFinished
    /// 404 `result_unavailable` — terminal, but the stored result is gone.
    case resultUnavailable
    /// 409 `approval_not_pending` — the desktop or a timeout already resolved it.
    case approvalNotPending
    /// 502 `agent_unreachable` — the Mac is up, Hermes is not.
    case agentUnreachable(String)
    /// 502 `dispatch_failed` — Hermes refused or returned no run id.
    case dispatchFailed(String)
    /// 400 `task_required` / `task_too_long` / `invalid_urgency` / `invalid_decision`.
    case invalidRequest(String)

    /// Anything else the service said, kept explicit rather than swallowed.
    case server(status: Int, code: String)

    /// A malformed or unexpected response body.
    case badResponse(String)

    /// Plain language for a human who is not going to read an error code.
    public var message: String {
        switch self {
        case .notPaired:
            return "This phone is no longer paired with your Mac. Pair it again from Iris on the desktop."
        case .unreachable(let detail):
            return "Could not reach Iris on your Mac. Check that Tailscale is connected on both devices and that Iris is running. (\(detail))"
        case .pairingRefused(let code):
            switch code {
            case "offer_expired":
                return "That pairing code expired. Show a fresh one in Iris on the desktop and scan it again."
            case "offer_used":
                return "That pairing code was already used. Show a fresh one in Iris on the desktop."
            case "offer_unknown":
                return "Your Mac is not offering this pairing code any more. Show a fresh one and scan it again."
            case "too_many_attempts", "rate_limited":
                return "Too many pairing attempts. Wait a minute, then show a fresh code in Iris on the desktop."
            case "invalid_json", "invalid_request":
                return "Your Mac did not understand the pairing request. Make sure both ends are on the same Iris version."
            default:
                return "Your Mac refused the pairing (\(code)). Show a fresh code in Iris on the desktop and try again."
            }
        case .tokenUnavailable:
            return "Your Mac could not issue a Gemini session token. Check that a Gemini API key is configured in Iris on the desktop."
        case .invalidVoice:
            return "Iris on your Mac does not have that voice any more."
        case .invalidPurpose:
            return "Iris on your Mac refused the kind of session token this app asked for. Update one of the two."
        case .pushUnavailable:
            return "This version of Iris on your Mac cannot register this phone for push notifications. Update Iris on the desktop."
        case .tasksUnavailable:
            return "This version of Iris on your Mac cannot take tasks from the phone. Update Iris on the desktop."
        case .taskUnknown:
            return "Iris on your Mac does not know that run."
        case .taskNotFinished:
            return "That Hermes run has not finished yet."
        case .resultUnavailable:
            return "That Hermes result could not be restored on your Mac."
        case .approvalNotPending:
            return "Hermes has no pending approval for that run — it was already answered on the Mac, or it timed out."
        case .agentUnreachable(let detail):
            return "Your Mac is reachable but Hermes is not responding on it."
                + (detail.isEmpty ? "" : " (\(detail))")
        case .dispatchFailed(let detail):
            return "Hermes refused the task." + (detail.isEmpty ? "" : " (\(detail))")
        case .invalidRequest(let code):
            return "Iris on your Mac refused the request (\(code))."
        case .server(let status, let code):
            return "Iris on your Mac returned an error (\(status) \(code))."
        case .badResponse(let detail):
            return "Iris on your Mac sent something this app could not read (\(detail))."
        }
    }

    /// True when the right response is to forget the credential and go back to
    /// the pairing screen.
    public var clearsPairing: Bool {
        if case .notPaired = self { return true }
        return false
    }
}

// MARK: - Client

/// Small async client. One instance per base URL; cheap to make per call.
public struct LinkClient: Sendable {

    public let baseURL: URL
    public let credential: String?
    private let session: URLSession

    public init(baseURL: URL, credential: String?, timeout: TimeInterval = 10) {
        self.init(baseURL: baseURL, credential: credential, timeout: timeout, protocolClasses: nil)
    }

    /// Test-only seam. A unit test puts a `URLProtocol` stub in front of the
    /// transport so the exact bytes of a request body can be asserted on
    /// without a server. No code path in the app passes anything but nil.
    init(baseURL: URL, credential: String?, timeout: TimeInterval = 10, protocolClasses: [AnyClass]?) {
        self.baseURL = baseURL
        self.credential = credential
        let config = URLSessionConfiguration.ephemeral
        if let protocolClasses { config.protocolClasses = protocolClasses }
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: config)
    }

    public init(paired: PairedDesktop, timeout: TimeInterval = 10) {
        self.init(
            baseURL: paired.baseURL ?? URL(string: "http://127.0.0.1")!,
            credential: paired.credential,
            timeout: timeout
        )
    }

    // MARK: Endpoints

    /// Redeems a one-time secret for this device's own credential. The only
    /// unauthenticated call in the whole client.
    public static func pair(
        host: String,
        port: Int,
        secret: String,
        deviceName: String,
        timeout: TimeInterval = 10
    ) async throws -> LinkPairResult {
        guard let base = URL(string: "http://\(host):\(port)") else {
            throw LinkError.unreachable("bad address")
        }
        let client = LinkClient(baseURL: base, credential: nil, timeout: timeout)
        let json = try await client.send(
            path: "/link/pair",
            method: "POST",
            body: ["secret": secret, "deviceName": deviceName],
            authenticated: false
        )
        guard
            let deviceId = json["deviceId"] as? String, !deviceId.isEmpty,
            let credential = json["credential"] as? String, !credential.isEmpty
        else {
            throw LinkError.badResponse("pairing response was incomplete")
        }
        return LinkPairResult(
            deviceId: deviceId,
            credential: credential,
            code: (json["code"] as? String) ?? ""
        )
    }

    public func status() async throws -> LinkStatus {
        let json = try await send(path: "/link/status", method: "GET", body: nil, authenticated: true)
        guard (json["ok"] as? Bool) == true else { throw LinkError.badResponse("status was not ok") }
        var status = LinkStatus(
            deviceId: (json["deviceId"] as? String) ?? "",
            deviceName: (json["deviceName"] as? String) ?? "",
            hermesReachable: (json["hermesReachable"] as? Bool) ?? false,
            userName: (json["userName"] as? String) ?? "",
            liveModel: (json["liveModel"] as? String) ?? "",
            voice: (json["voice"] as? String) ?? "",
            accent: (json["accent"] as? String) ?? "",
            voices: ((json["voices"] as? [[String: Any]]) ?? []).compactMap(LinkVoice.init(json:)),
            // §13.3: `default_voice` falls back to the desktop's `voice` only
            // because the desktop already does that; nothing is invented here.
            defaultVoice: (json["default_voice"] as? String) ?? "",
            pushConfigured: (json["pushConfigured"] as? Bool) ?? false
        )
        if let build = json["build"] as? [String: Any] {
            let commit = (build["commit"] as? String) ?? ""
            let version = (build["version"] as? String) ?? ""
            let dirty = (build["dirty"] as? Bool) ?? false
            status.macBuild = commit.isEmpty ? version : "\(commit)\(dirty ? "+" : "")"
            status.macStartedAtMs = (build["started_at"] as? NSNumber)?.doubleValue ?? 0
        }
        return status
    }

    // MARK: Push registration (LINK_API.md §11)

    /// `PUT /link/push-token`. Idempotent, one token per paired device.
    /// The token is never logged and never put in an error message.
    @discardableResult
    public func registerPushToken(_ token: String, environment: PushEnvironment) async throws -> Bool {
        let json = try await send(
            path: "/link/push-token",
            method: "PUT",
            body: ["token": token, "environment": environment.rawValue],
            authenticated: true
        )
        return (json["pushEnabled"] as? Bool) ?? false
    }

    /// `DELETE /link/push-token`. Safe when nothing is registered.
    public func unregisterPushToken() async throws {
        _ = try await send(path: "/link/push-token", method: "DELETE", body: nil, authenticated: true)
    }

    /// Mints a fresh ephemeral Gemini token. Single use, with a 60 s window to
    /// start a session, so callers fetch one immediately before connecting and
    /// never keep it.
    ///
    /// `resumeHandle` asks the Mac to reconnect this session into an existing
    /// conversation. It has to be asked for here rather than sent on the
    /// socket: on the constrained endpoint the token's config replaces the
    /// client's setup frame, `sessionResumption` included, so a handle the
    /// phone puts in its own setup is silently ignored (verified against the
    /// real API — see `LiveClient.Config.resumeHandle`). The only path that
    /// works is a token minted with the handle already inside it.
    ///
    /// A single use is spent per connection either way: a token that has
    /// opened a session is refused with 1011 "Token has been used too many
    /// times" if it is offered again, handle or no handle. So every reconnect
    /// mints a new token.
    ///
    /// The desktop answers with `resumed: true` when it honored the handle.
    /// A build that does not implement `resume_handle` simply omits the field
    /// and mints an ordinary fresh-conversation token, which the caller then
    /// correctly treats as a new session.
    /// `voice` is a name out of `GET /link/status` → `voices` (§13.1). It is
    /// sent on EVERY session mint, fresh and resume alike, so a reconnect
    /// cannot flip the voice under a conversation that is still going. An
    /// unknown name comes back as `400 invalid_voice`, never as a silent
    /// substitution.
    public func geminiToken(
        resumeHandle: String? = nil,
        voice: String? = nil,
        purpose: LinkTokenPurpose = .session
    ) async throws -> LinkToken {
        var body: [String: Any] = [:]
        let handle = resumeHandle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !handle.isEmpty { body["resume_handle"] = handle }
        let wanted = voice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !wanted.isEmpty { body["voice"] = wanted }
        // `session` is the default on the wire; sending it changes nothing, and
        // omitting it keeps an older desktop's `{}` behavior exactly.
        if purpose != .session { body["purpose"] = purpose.rawValue }
        let json = try await send(path: "/link/gemini-token", method: "POST", body: body, authenticated: true)
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw LinkError.badResponse("token response carried no token")
        }
        return LinkToken(
            token: token,
            expiresAt: json["expiresAt"] as? String,
            newSessionExpiresAt: json["newSessionExpiresAt"] as? String,
            model: (json["model"] as? String) ?? "",
            resumed: !handle.isEmpty && (json["resumed"] as? Bool) == true,
            voice: (json["voice"] as? String) ?? "",
            purpose: (json["purpose"] as? String) ?? purpose.rawValue
        )
    }

    // MARK: Transport

    /// Authenticated JSON call. The task API in LinkTasks.swift goes through
    /// this and nothing else.
    func request(path: String, method: String, body: [String: Any]?) async throws -> [String: Any] {
        try await send(path: path, method: method, body: body, authenticated: true)
    }

    func send(
        path: String,
        method: String,
        body: [String: Any]?,
        authenticated: Bool
    ) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw LinkError.unreachable("bad address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            guard let credential, !credential.isEmpty else { throw LinkError.notPaired }
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // Unreachable is a distinct outcome from refused: the spec requires
            // the phone to say which of the two happened.
            throw LinkError.unreachable(Self.describe(error))
        } catch {
            throw LinkError.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LinkError.badResponse("no HTTP response")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (json["error"] as? String) ?? ""

        if http.statusCode == 401 && code == "not_paired" { throw LinkError.notPaired }
        if http.statusCode == 401 { throw LinkError.notPaired }

        guard (200..<300).contains(http.statusCode) else {
            if path.hasPrefix("/link/pair") {
                throw LinkError.pairingRefused(code.isEmpty ? "http_\(http.statusCode)" : code)
            }
            // `message` is the only free text the service returns, and the
            // contract promises it never carries a credential or a key.
            let detail = (json["message"] as? String) ?? ""
            switch code {
            case "token_unavailable": throw LinkError.tokenUnavailable
            case "invalid_voice": throw LinkError.invalidVoice
            case "invalid_purpose": throw LinkError.invalidPurpose
            case "push_unavailable": throw LinkError.pushUnavailable
            case "tasks_unavailable": throw LinkError.tasksUnavailable
            case "task_unknown": throw LinkError.taskUnknown
            case "task_not_finished": throw LinkError.taskNotFinished
            case "result_unavailable": throw LinkError.resultUnavailable
            case "approval_not_pending": throw LinkError.approvalNotPending
            case "agent_unreachable": throw LinkError.agentUnreachable(detail)
            case "dispatch_failed": throw LinkError.dispatchFailed(detail)
            case "task_required", "task_too_long", "invalid_urgency", "invalid_decision",
                 "invalid_token", "invalid_environment",
                 "invalid_json", "payload_too_large", "unsupported_media_type":
                throw LinkError.invalidRequest(code)
            default:
                throw LinkError.server(status: http.statusCode, code: code.isEmpty ? "unknown" : code)
            }
        }
        if json.isEmpty { throw LinkError.badResponse("empty body") }
        return json
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: return "timed out"
        case .cannotConnectToHost: return "connection refused"
        case .cannotFindHost: return "address not found"
        case .networkConnectionLost: return "connection lost"
        case .notConnectedToInternet: return "no network"
        case .dataNotAllowed: return "network not permitted"
        default: return "network error \(error.code.rawValue)"
        }
    }
}
