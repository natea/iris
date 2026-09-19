//
//  main.swift  —  LinkProbe
//
//  A macOS command-line exercise of the *real* app code: the deep-link parser
//  and pairing-code derivation from Sources/LinkClient.swift, the Iris Link
//  HTTP client from the same file, and the Gemini Live client from
//  Sources/LiveClient.swift — including its ephemeral-token endpoint.
//
//  It is driven by a throwaway Node harness that runs a real Iris Link server
//  (electron/irisLinkServer.mjs + electron/pairingStore.mjs) on 127.0.0.1, so
//  the whole pairing → token → Live → refusal path can be checked without a
//  phone. See Tools/run-link-probe.sh.
//
//  Build + run:
//      ./Tools/run-link-probe.sh            (builds the binary only)
//      swiftc -O -o /tmp/linkprobe \
//          Sources/LiveClient.swift Sources/LinkClient.swift Tools/LinkProbe/main.swift
//
//  Subcommands (each prints machine-readable lines and exits non-zero on a
//  failed expectation):
//      code   <deep-link>
//      pair   <deep-link> <credential-file>
//      status <credential-file>
//      live   <credential-file> <token-file> [prompt]
//      reuse  <token-file>
//
//  Nothing here prints a secret, a credential or a token: credentials and
//  tokens move between steps through files, and only their lengths are shown.
//

import Foundation

// The probe — and only the probe — is allowed past the parser's 100.64.0.0/10
// rule, so it can drive a loopback test server. The app never passes this.
let allowAnyHostForTesting = true

func fail(_ message: String) -> Never {
    print("FAIL \(message)")
    exit(3)
}

func read(_ path: String) -> String {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("could not read \(path)")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

func write(_ value: String, to path: String) {
    do {
        try value.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        fail("could not write \(path)")
    }
}

func loadPairing(_ path: String) -> PairedDesktop {
    let data = Data(read(path).utf8)
    guard let pairing = try? JSONDecoder().decode(PairedDesktop.self, from: data) else {
        fail("credential file was not a stored pairing")
    }
    return pairing
}

func describe(_ error: Error) -> String {
    if let link = error as? LinkError {
        switch link {
        case .notPaired: return "notPaired"
        case .unreachable(let detail): return "unreachable(\(detail))"
        case .pairingRefused(let code): return "pairingRefused(\(code))"
        case .tokenUnavailable: return "tokenUnavailable"
        case .server(let status, let code): return "server(\(status),\(code))"
        case .badResponse(let detail): return "badResponse(\(detail))"
        }
    }
    return "other(\(error))"
}

func linkMessage(_ error: Error) -> String {
    (error as? LinkError)?.message ?? "\(error)"
}

// MARK: - Live helpers

struct LiveOutcome {
    var setupComplete = false
    var turnComplete = false
    var audioChunks = 0
    var audioBytes = 0
    var transcript = ""
    var authorizationFailure: (code: Int, reason: String?)?
    var closeCode: Int?
    var closeReason: String?
    var errors: [String] = []
}

func runLive(credential: LiveClient.Credential, model: String, prompt: String, timeout: UInt64) async -> LiveOutcome {
    var outcome = LiveOutcome()
    let client = LiveClient(config: .init(
        credential: credential,
        model: model,
        voiceName: "Iapetus",
        systemInstruction: "Answer in one very short sentence."
    ))
    let stream = await client.events()
    await client.connect()
    let deadline = Task {
        try? await Task.sleep(nanoseconds: timeout)
        await client.close()
    }
    for await event in stream {
        switch event {
        case .opened:
            print("  socket open")
        case .setupComplete:
            outcome.setupComplete = true
            print("  setupComplete")
            await client.sendTextTurn(prompt)
        case .audio(let data):
            outcome.audioChunks += 1
            outcome.audioBytes += data.count
        case .outputTranscript(let text):
            outcome.transcript += text
        case .inputTranscript, .text, .interrupted, .generationComplete, .sessionResumption:
            break
        case .turnComplete:
            outcome.turnComplete = true
            await client.close()
        case .goAway(let left):
            print("  goAway \(left ?? "")")
        case .authorizationFailed(let code, let reason):
            outcome.authorizationFailure = (code, reason)
        case .error(let message):
            outcome.errors.append(message)
        case .closed(let code, let reason):
            outcome.closeCode = code
            outcome.closeReason = reason
        }
    }
    deadline.cancel()
    return outcome
}

// MARK: - Commands

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("no subcommand") }

switch command {

// (a) Does Swift derive the same six digits the desktop shows?
case "code":
    guard args.count >= 2, let url = URL(string: args[1]) else { fail("usage: code <deep-link>") }
    do {
        let offer = try IrisLinkDeepLink.parse(url, allowAnyHost: allowAnyHostForTesting)
        print("HOST \(offer.host)")
        print("PORT \(offer.port)")
        print("NAME \(offer.desktopName)")
        print("CODE \(offer.code)")
    } catch let error as PairingLinkError {
        print("REJECTED \(error)")
        print("MESSAGE \(error.message)")
        exit(4)
    }

// Strict-parser checks, including the 100.64/10 rule the app enforces.
case "parse-strict":
    guard args.count >= 2, let url = URL(string: args[1]) else { fail("usage: parse-strict <deep-link>") }
    do {
        let offer = try IrisLinkDeepLink.parse(url)  // no bypass
        print("ACCEPTED \(offer.address)")
    } catch let error as PairingLinkError {
        print("REJECTED \(error)")
        print("MESSAGE \(error.message)")
    }

// (b) Redeem a scanned offer. Run twice to see the second one refused.
case "pair":
    guard args.count >= 3, let url = URL(string: args[1]) else { fail("usage: pair <deep-link> <cred-file>") }
    let credFile = args[2]
    do {
        let offer = try IrisLinkDeepLink.parse(url, allowAnyHost: allowAnyHostForTesting)
        print("CODE \(offer.code)")
        let result = try await LinkClient.pair(
            host: offer.host,
            port: offer.port,
            secret: offer.secret,
            deviceName: "LinkProbe (macOS)"
        )
        let record = PairedDesktop(
            host: offer.host,
            port: offer.port,
            deviceId: result.deviceId,
            credential: result.credential,
            desktopName: offer.desktopName
        )
        let data = try JSONEncoder().encode(record)
        write(String(decoding: data, as: UTF8.self), to: credFile)
        print("PAIR_OK deviceId=\(result.deviceId) credentialLength=\(result.credential.count) serverCode=\(result.code)")
    } catch let error as PairingLinkError {
        print("PARSE_REJECTED \(error)")
        exit(4)
    } catch {
        print("PAIR_REFUSED \(describe(error))")
        print("MESSAGE \(linkMessage(error))")
        exit(5)
    }

// (c) and (f): the authenticated status call, and what a revoked device sees.
case "status":
    guard args.count >= 2 else { fail("usage: status <cred-file>") }
    let pairing = loadPairing(args[1])
    do {
        let status = try await LinkClient(paired: pairing).status()
        print("STATUS_OK deviceName=\(status.deviceName) model=\(status.liveModel) voice=\(status.voice) hermesReachable=\(status.hermesReachable) userName=\(status.userName)")
    } catch {
        print("STATUS_ERROR \(describe(error))")
        print("MESSAGE \(linkMessage(error))")
        if case LinkError.notPaired = error { exit(6) }
        exit(5)
    }

// (d) A token fetched through Link opens a real Live session from Swift.
case "live":
    guard args.count >= 3 else { fail("usage: live <cred-file> <token-file> [prompt]") }
    let pairing = loadPairing(args[1])
    let tokenFile = args[2]
    let prompt = args.count > 3 ? args[3] : "Say hello in five words."
    let minted: LinkToken
    do {
        minted = try await LinkClient(paired: pairing).geminiToken()
    } catch {
        print("TOKEN_ERROR \(describe(error))")
        print("MESSAGE \(linkMessage(error))")
        exit(5)
    }
    print("TOKEN_OK length=\(minted.token.count) prefix=\(minted.token.prefix(12))… model=\(minted.model) expiresAt=\(minted.expiresAt ?? "-") newSessionExpiresAt=\(minted.newSessionExpiresAt ?? "-")")
    write(minted.token, to: tokenFile)
    let outcome = await runLive(
        credential: .ephemeralToken(minted.token),
        model: minted.model.isEmpty ? "models/gemini-3.1-flash-live-preview" : minted.model,
        prompt: prompt,
        timeout: 45_000_000_000
    )
    for message in outcome.errors { print("  error: \(message)") }
    print("LIVE setupComplete=\(outcome.setupComplete) turnComplete=\(outcome.turnComplete) audioChunks=\(outcome.audioChunks) audioBytes=\(outcome.audioBytes) close=\(outcome.closeCode.map(String.init) ?? "-")")
    print("TRANSCRIPT \(outcome.transcript)")
    exit(outcome.setupComplete && outcome.audioBytes > 0 ? 0 : 7)

// (e) The same token a second time must be refused, and classified as an
//     authorization failure rather than a network error.
case "reuse":
    guard args.count >= 2 else { fail("usage: reuse <token-file>") }
    let token = read(args[1])
    let model = args.count > 2 ? args[2] : "models/gemini-3.1-flash-live-preview"
    let outcome = await runLive(
        credential: .ephemeralToken(token),
        model: model,
        prompt: "Say hello in five words.",
        timeout: 25_000_000_000
    )
    for message in outcome.errors { print("  error: \(message)") }
    if let failure = outcome.authorizationFailure {
        print("AUTH_FAILED code=\(failure.code) reason=\(failure.reason ?? "-")")
        print("REUSE setupComplete=\(outcome.setupComplete) audioBytes=\(outcome.audioBytes)")
        exit(0)
    }
    print("NO_AUTH_FAILURE setupComplete=\(outcome.setupComplete) audioBytes=\(outcome.audioBytes) close=\(outcome.closeCode.map(String.init) ?? "-") reason=\(outcome.closeReason ?? "-")")
    exit(8)

default:
    fail("unknown subcommand \(command)")
}
