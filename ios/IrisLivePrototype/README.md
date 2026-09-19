# Iris Live Prototype (iOS)

Throwaway prototype for OpenSpec task 1.1: prove that a plain Swift
`URLSessionWebSocketTask` client can drive the Gemini Live API — open a session,
stream 16 kHz mono PCM16 microphone audio up, and play the 24 kHz PCM16 audio
that comes back, including barge-in.

There is no Swift SDK for the Live API, so `LiveClient.swift` implements the
`BidiGenerateContent` WebSocket protocol by hand.

## Files

| File | What it does |
| --- | --- |
| `Sources/LiveClient.swift` | Foundation-only actor: connect, `setup`, `realtimeInput` audio, `clientContent` text, parse server frames, emit an `AsyncStream<LiveEvent>`. Compiles for iOS **and** macOS. |
| `Sources/AudioEngine.swift` | `AVAudioSession` + `AVAudioEngine`: mic tap → `AVAudioConverter` → 40 ms 16 kHz Int16 chunks; `AVAudioPlayerNode` playback of 24 kHz PCM16; `flushPlayback()` for barge-in. Rebuilds the whole graph on route/configuration changes (Bluetooth) and publishes an `AudioStatus` snapshot. iOS only. |
| `Sources/ContentView.swift` | SwiftUI harness: key field, Start/Stop, status dot, rolling transcript, error line, received-audio counter, and the route/engine debug lines. |
| `Sources/IrisLivePrototypeApp.swift` | `@main` app entry. |
| `Tools/main.swift` | macOS CLI probe — reuses `LiveClient.swift`, reads the key from `~/.iris/.env`, sends one text turn, counts audio bytes. |
| `Tools/run-probe.sh` | Builds and runs the probe. |
| `project.yml` | XcodeGen spec (bundle id `app.iris.liveprototype`, iOS 18, Swift 5 mode). |

## Open and run on a phone

```bash
cd ios/IrisLivePrototype
xcodegen generate          # regenerates IrisLivePrototype.xcodeproj
open IrisLivePrototype.xcodeproj
```

1. Select the `IrisLivePrototype` target → **Signing & Capabilities** → pick your
   team (`DEVELOPMENT_TEAM` is deliberately blank in `project.yml`).
2. Plug in an iPhone, select it as the run destination, and Run.
   Use a real device: the simulator's microphone and AEC do not represent
   anything useful.
3. Paste a Gemini API key (or an ephemeral token) into the field. It is held in
   memory only — never written to disk, never logged.
4. Tap **Start**, accept the microphone prompt.

`xcodegen generate` is only needed after editing `project.yml` or adding files.

## Simulator build check

```bash
xcodebuild -project IrisLivePrototype.xcodeproj -scheme IrisLivePrototype \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

## Protocol probe (no phone needed)

```bash
./Tools/run-probe.sh "Say hello in five words."
```

Reads `GEMINI_API_KEY` from `~/.iris/.env`, connects, waits for `setupComplete`,
sends one `clientContent` turn, and prints how much audio came back. Exits 0 when
`setupComplete` arrived and audio bytes > 0.

## 30-second test script

Hold the phone at normal speaking distance, **speaker on** (the session uses
`.defaultToSpeaker`, which is the interesting case for echo cancellation).

1. **0–5 s** — Tap Start, wait for the status dot to turn green ("Live").
   Say: *"Hello, can you hear me?"*
   - Expect a "You" line with your words, then an "Iris" line and audible speech.
2. **5–15 s** — Ask a question that produces a longer answer:
   *"What are three things worth seeing in Kyoto?"*
   - Expect continuous audio and a growing "Iris" transcript.
3. **15–25 s** — **Interrupt it mid-sentence**: while Iris is still talking, say
   loudly *"Stop — tell me about Osaka instead."*
   - Expect an `[interrupted]` line, playback to cut off almost immediately, and
     a new answer to start.
4. **25–30 s** — Tap Stop. Status goes grey, no crash, no audio tail.

### What to observe and report

- Did playback actually stop on barge-in, or did the tail keep playing?
- Did Iris interrupt *itself* (the mic hearing the speaker)? That is the
  `.voiceChat` echo-cancellation question.
- Latency from finishing your sentence to first audio out.
- Any dropouts, robotic artefacts, or pitch problems (sample-rate conversion).
- The chunks/KB counter in the header — it should climb whenever Iris speaks.
- Any text on the red error line, and the close code if the session drops.

## Bluetooth test script

This is the one that needs a real phone *and* a real headset — neither the
simulator nor any automated check here can exercise a Bluetooth route, so
Bluetooth behaviour is **unverified by the build**. It has to be read off the
screen by a human.

Three lines under the status dot carry everything you need:

```
In: AirPods Pro (HFP) 16000 Hz · Out: AirPods Pro 16000 Hz
engine: running · graph in 16000 Hz · rebuilds 1
in 128 chunks → scheduled 128 · dropped 0 · last route event: newDeviceAvailable · last rebuild: route:newDeviceAvailable
```

- **line 1** — the live route: port names and the session's hardware sample
  rate. `(HFP)` is the two-way Bluetooth voice profile; `(A2DP)` would be
  output-only and would mean the mic is somewhere else.
- **line 2** — whether the engine is running, the sample rate the *graph* was
  built at (it must match line 1 — if it says 48000 while line 1 says 16000,
  the graph is stale), and how many rebuilds have happened.
- **line 3** — `chunks` is audio received from Gemini, `scheduled` is buffers
  handed to the player, `dropped` is buffers thrown away because the engine was
  not running. This is what separates "no audio arrived" from "audio arrived and
  was not played".

`Xcode > Console` also prints a `[audio]` line for every route change,
configuration change, interruption, and rebuild. No key material is logged.

### (a) Headset already connected before Start

1. Connect the headset, confirm iOS is routed to it, then launch and tap Start.
2. Say *"Hello, can you hear me?"* and listen **in the headset**.

Expect: line 1 names the headset for both In and Out, most likely at 16000 Hz
(8000 Hz on an older headset); line 2 shows `running` with the *same* rate and
`rebuilds 0` or `1`; line 3 shows `scheduled` climbing with `chunks` and
`dropped 0`.

Report: the full text of all three lines, whether you heard Gemini, and whether
Gemini heard you (the "You" transcript line).

### (b) Connect the headset mid-session

1. Start on the built-in speaker, confirm audio works, and leave Gemini talking.
2. Put the headset on / connect it while it is speaking.

Expect: a short gap (roughly 0.2–0.5 s) while the graph rebuilds, then audio
continues **in the headset**; line 1 switches to the headset; line 2's rate
follows it and `rebuilds` goes up by one (not by five — the debounce should
collapse the burst); `last route event: newDeviceAvailable`.

Report: did audio come back at all, how long the gap was, the three lines
afterwards, and the `rebuilds` count.

### (c) Disconnect the headset mid-session

1. With audio playing in the headset, switch it off or disconnect it.

Expect: audio moves to the **loudspeaker** (not the earpiece — that is what
`.defaultToSpeaker` is for); line 1 shows `built-in mic` / `speaker` back at
48000 Hz; `rebuilds` goes up by one; `last route event: oldDeviceUnavailable`.

Report: where the audio went (speaker vs earpiece vs silence), the three lines,
and whether the mic still works afterwards.

### If it is still silent

Read line 3 first:

- `chunks` stuck at 0 → nothing is arriving from Gemini; it is a network/session
  problem, not an audio one.
- `chunks` climbing but `scheduled` flat and `dropped` climbing → the engine is
  not running; read line 2 and the `[audio]` log for the failed rebuild.
- `chunks` and `scheduled` both climbing, still silent → the graph is fine and
  the audio is going somewhere you cannot hear. Compare line 1's Out port
  against where you are listening, and compare line 2's graph rate to line 1's
  hardware rate.
- Line 1 shows `(A2DP)` instead of `(HFP)` → the session picked an output-only
  profile; report it, the mic will be on the phone.

## Wire format that was verified to work

Setup (first frame, sent as a text frame):

```json
{"setup":{
  "model":"models/gemini-3.1-flash-live-preview",
  "generationConfig":{
    "responseModalities":["AUDIO"],
    "speechConfig":{"voiceConfig":{"prebuiltVoiceConfig":{"voiceName":"Iapetus"}}},
    "temperature":0.8
  },
  "inputAudioTranscription":{},
  "outputAudioTranscription":{},
  "systemInstruction":{"parts":[{"text":"…"}]}
}}
```

Microphone audio up:

```json
{"realtimeInput":{"audio":{"data":"<base64 PCM16 LE mono>","mimeType":"audio/pcm;rate=16000"}}}
```

Text turn up:

```json
{"clientContent":{"turns":[{"role":"user","parts":[{"text":"…"}]}],"turnComplete":true}}
```

Down: `{"setupComplete":{}}`, then `{"serverContent":{…}}` carrying
`inputTranscription.text`, `outputTranscription.text`,
`modelTurn.parts[].inlineData.{data,mimeType}` (base64 PCM16 @ 24 kHz),
`interrupted`, `generationComplete`, `turnComplete`; plus top-level `goAway` and
`sessionResumptionUpdate`. Frames may arrive as binary — decode both.
