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

public struct LinkStatus: Sendable, Equatable {
    public let deviceId: String
    public let deviceName: String
    public let hermesReachable: Bool
    public let userName: String
    public let liveModel: String
    public let voice: String
    public let accent: String
}

public struct LinkToken: Sendable, Equatable {
    public let token: String
    public let expiresAt: String?
    public let newSessionExpiresAt: String?
    public let model: String
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
        self.baseURL = baseURL
        self.credential = credential
        let config = URLSessionConfiguration.ephemeral
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
        return LinkStatus(
            deviceId: (json["deviceId"] as? String) ?? "",
            deviceName: (json["deviceName"] as? String) ?? "",
            hermesReachable: (json["hermesReachable"] as? Bool) ?? false,
            userName: (json["userName"] as? String) ?? "",
            liveModel: (json["liveModel"] as? String) ?? "",
            voice: (json["voice"] as? String) ?? "",
            accent: (json["accent"] as? String) ?? ""
        )
    }

    /// Mints a fresh ephemeral Gemini token. Single use, with a 60 s window to
    /// start a session, so callers fetch one immediately before connecting and
    /// never keep it.
    public func geminiToken() async throws -> LinkToken {
        let json = try await send(path: "/link/gemini-token", method: "POST", body: [:], authenticated: true)
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw LinkError.badResponse("token response carried no token")
        }
        return LinkToken(
            token: token,
            expiresAt: json["expiresAt"] as? String,
            newSessionExpiresAt: json["newSessionExpiresAt"] as? String,
            model: (json["model"] as? String) ?? ""
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
            case "tasks_unavailable": throw LinkError.tasksUnavailable
            case "task_unknown": throw LinkError.taskUnknown
            case "task_not_finished": throw LinkError.taskNotFinished
            case "result_unavailable": throw LinkError.resultUnavailable
            case "approval_not_pending": throw LinkError.approvalNotPending
            case "agent_unreachable": throw LinkError.agentUnreachable(detail)
            case "dispatch_failed": throw LinkError.dispatchFailed(detail)
            case "task_required", "task_too_long", "invalid_urgency", "invalid_decision",
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
