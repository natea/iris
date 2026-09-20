//
//  main.swift  —  VoicePreviewProbe
//
//  Proves the §13 voice-preview protocol with the REAL app code, from macOS,
//  without a phone: the same Sources/LinkClient.swift that the app uses to
//  mint a token, and the same Sources/LiveClient.swift that opens the Live
//  socket. Only the audio sink is different — there is no AVAudioEngine here,
//  so the PCM is counted rather than played.
//
//  It is driven by a throwaway Node harness that runs the REAL Iris Link
//  server with a mintGeminiToken copied from electron/main.mjs, so the token
//  really is minted by Gemini with electron/mobileSession.mjs's preview
//  config and electron/voiceDialect.mjs's catalogue.
//
//  Build:
//      ./Tools/run-voice-preview-probe.sh
//
//  Subcommands:
//      pair    <deep-link> <credential-file>
//      voices  <credential-file>
//      preview <credential-file> <voice>
//      refuse  <credential-file> <not-a-voice>
//
//  Nothing here prints a credential or a token — only lengths and prefixes
//  that cannot be one.
//

import Foundation

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

func loadPairing(_ path: String) -> PairedDesktop {
    guard let data = read(path).data(using: .utf8),
          let paired = try? JSONDecoder().decode(PairedDesktop.self, from: data)
    else { fail("could not decode the pairing at \(path)") }
    return paired
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: voicepreviewprobe pair|voices|preview|refuse …")
}

switch command {

case "pair":
    guard arguments.count >= 3 else { fail("pair <deep-link> <credential-file>") }
    guard let url = URL(string: arguments[1]) else { fail("bad deep link") }
    let offer = try! IrisLinkDeepLink.parse(url, allowAnyHost: allowAnyHostForTesting)
    print("OFFER \(offer.address) code \(offer.code)")
    let result = try! await LinkClient.pair(
        host: offer.host, port: offer.port, secret: offer.secret, deviceName: "Probe Mac"
    )
    let record = PairedDesktop(
        host: offer.host, port: offer.port, deviceId: result.deviceId,
        credential: result.credential, desktopName: offer.desktopName
    )
    let encoded = try! JSONEncoder().encode(record)
    try! encoded.write(to: URL(fileURLWithPath: arguments[2]))
    print("PAIRED device \(result.deviceId) credential \(result.credential.count) chars")

case "voices":
    guard arguments.count >= 2 else { fail("voices <credential-file>") }
    let status = try! await LinkClient(paired: loadPairing(arguments[1])).status()
    print("VOICES \(status.voices.count)")
    print("DEFAULT \(status.defaultVoice)")
    print("ACCENT \(status.accent)")
    for voice in status.voices.prefix(3) { print("VOICE \(voice.label)") }
    guard status.voices.contains(where: { $0.name == "Algenib" }) else {
        fail("the catalogue does not carry Algenib")
    }
    guard !status.defaultVoice.isEmpty else { fail("no default_voice") }

case "refuse":
    guard arguments.count >= 3 else { fail("refuse <credential-file> <name>") }
    do {
        _ = try await LinkClient(paired: loadPairing(arguments[1]))
            .geminiToken(voice: arguments[2], purpose: .preview)
        fail("an unknown voice was NOT refused")
    } catch LinkError.invalidVoice {
        print("REFUSED invalid_voice (as the contract says)")
    } catch {
        fail("wrong error for an unknown voice: \(error)")
    }

case "preview":
    guard arguments.count >= 3 else { fail("preview <credential-file> <voice>") }
    let paired = loadPairing(arguments[1])
    let wanted = arguments[2]

    // 1. §13.5 step 1 — a token for THIS voice, for a preview.
    let minted = try! await LinkClient(paired: paired).geminiToken(voice: wanted, purpose: .preview)
    print("TOKEN purpose \(minted.purpose) voice \(minted.voice) model \(minted.model)")
    print("TOKEN_LIFETIME expires \(minted.expiresAt ?? "?") newSession \(minted.newSessionExpiresAt ?? "?")")
    guard minted.purpose == "preview" else { fail("the desktop did not mint a preview token") }
    guard minted.voice == wanted else { fail("the token carries \(minted.voice), not \(wanted)") }

    // 2. §13.5 step 2 — an ordinary Live connection, EMPTY setup config.
    let client = LiveClient(config: .init(
        credential: .ephemeralToken(minted.token),
        model: minted.model,
        minimalSetup: true
    ))

    var audioBytes = 0
    var audioChunks = 0
    var transcript = ""
    var sawSetup = false
    var sawTurnComplete = false

    let stream = await client.events()
    await client.connect()

    let watchdog = Task {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        await client.close()
    }

    for await event in stream {
        switch event {
        case .setupComplete:
            sawSetup = true
            print("SETUP_COMPLETE")
            // 3. §13.5 step 3 — exactly one turn, exactly this text.
            await client.sendTextTurn("Go.", turnComplete: true)
            print("SENT_TURN \"Go.\"")
        case .audio(let pcm):
            audioChunks += 1
            audioBytes += pcm.count
        case .outputTranscript(let text):
            transcript += text
        case .toolCall(let calls):
            fail("a preview token offered tools: \(calls.map(\.name))")
        case .turnComplete:
            sawTurnComplete = true
            print("TURN_COMPLETE")
            // 4./5. stop and close as soon as the turn ends.
            await client.close()
        case .authorizationFailed(let code, let reason):
            fail("token refused: \(code) \(reason ?? "")")
        default:
            break
        }
    }
    watchdog.cancel()

    print("AUDIO chunks \(audioChunks) bytes \(audioBytes) (~\(String(format: "%.1f", Double(audioBytes) / 48_000.0))s at 24 kHz mono PCM16)")
    print("TRANSCRIPT \(transcript.trimmingCharacters(in: .whitespacesAndNewlines))")

    guard sawSetup else { fail("the socket never became usable") }
    guard sawTurnComplete else { fail("no turnComplete — the preview never ended by itself") }
    guard audioBytes > 0 else { fail("no audio arrived") }
    guard transcript.localizedCaseInsensitiveContains(wanted) else {
        fail("the sample line does not name \(wanted)")
    }
    guard transcript.localizedCaseInsensitiveContains("Iris") else {
        fail("the sample line is not Iris's")
    }
    print("OK preview of \(wanted) played and ended")

default:
    fail("unknown command \(command)")
}
