//
//  main.swift  —  LiveProbe
//
//  A macOS command-line proof that LiveClient.swift really speaks the Gemini
//  Live protocol: connect, wait for setupComplete, send one text turn, and
//  count the PCM audio bytes that come back. No microphone, no speakers.
//
//  Build + run:
//      ./Tools/run-probe.sh
//  or:
//      swiftc -O -o /tmp/liveprobe Sources/LiveClient.swift Tools/main.swift
//      /tmp/liveprobe "say hello in five words"
//
//  The key is read from ~/.iris/.env (GEMINI_API_KEY) and is never printed.
//

import Foundation

func loadAPIKey() -> String? {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".iris/.env")
    guard let contents = try? String(contentsOf: path, encoding: .utf8) else { return nil }
    for rawLine in contents.split(whereSeparator: \.isNewline) {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("export ") { line.removeFirst("export ".count) }
        guard line.hasPrefix("GEMINI_API_KEY") else { continue }
        guard let equals = line.firstIndex(of: "=") else { continue }
        var value = String(line[line.index(after: equals)...])
            .trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == "\"" || first == "'",
           value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
    return nil
}

guard let apiKey = loadAPIKey() else {
    FileHandle.standardError.write(Data("No GEMINI_API_KEY in ~/.iris/.env\n".utf8))
    exit(1)
}

let prompt = CommandLine.arguments.dropFirst().first ?? "Say hello in five words."

let client = LiveClient(config: .init(
    apiKey: apiKey,
    voiceName: "Iapetus",
    systemInstruction: "Answer in one very short sentence."
))

var audioChunks = 0
var audioBytes = 0
var outputTranscript = ""
var sawSetupComplete = false
var sawTurnComplete = false

let stream = await client.events()
await client.connect()

let deadline = Task {
    try? await Task.sleep(nanoseconds: 45_000_000_000)
    await client.close()
}

for await event in stream {
    switch event {
    case .opened:
        print("socket open")
    case .setupComplete:
        sawSetupComplete = true
        print("setupComplete")
        await client.sendTextTurn(prompt)
        print("sent clientContent turn: \(prompt)")
    case .audio(let data):
        audioChunks += 1
        audioBytes += data.count
    case .outputTranscript(let text):
        outputTranscript += text
    case .inputTranscript(let text):
        print("input transcript: \(text)")
    case .text(let text):
        print("model text part: \(text)")
    case .interrupted:
        print("interrupted")
    case .generationComplete:
        print("generationComplete")
    case .turnComplete:
        sawTurnComplete = true
        print("turnComplete")
        await client.close()
    case .goAway(let timeLeft):
        print("goAway \(timeLeft ?? "")")
    case .sessionResumption:
        break
    case .error(let message):
        print("error: \(message)")
    case .closed(let code, let reason):
        print("closed code=\(code) reason=\(reason ?? "-")")
    }
}

deadline.cancel()

print("""

--- result ---
setupComplete:      \(sawSetupComplete)
turnComplete:       \(sawTurnComplete)
audio chunks:       \(audioChunks)
audio bytes:        \(audioBytes)  (~\(String(format: "%.2f", Double(audioBytes) / 48_000.0)) s at 24 kHz PCM16)
output transcript:  \(outputTranscript)
""")

exit(sawSetupComplete && audioBytes > 0 ? 0 : 2)
