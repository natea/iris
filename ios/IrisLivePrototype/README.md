# Iris Live Prototype (iOS)

Prototype for the iOS voice companion. Two things are proved here:

1. A plain Swift `URLSessionWebSocketTask` client can drive the Gemini Live API —
   open a session, stream 16 kHz mono PCM16 microphone audio up, and play the
   24 kHz PCM16 audio that comes back, including barge-in.
2. The phone can pair with the Iris desktop over Tailscale and run those
   sessions on **short-lived tokens minted by the Mac**, with no Gemini API key
   on the phone at all.
3. From that session the phone can send real work to Hermes on the Mac — behind
   a two-step confirmation gate enforced in code, not in the prompt — track the
   run, and announce the result when it lands.

`LINK_API.md` in this folder is the contract the desktop wrote and this app
implements: every route, every error code, every tool's exact result JSON, the
gate's state machine, the system-event templates, and the announced/undelivered
protocol.

There is no Swift SDK for the Live API, so `LiveClient.swift` implements the
`BidiGenerateContent` WebSocket protocol by hand.

## How a token reaches the socket

An API key and an ephemeral token are **not** interchangeable on this API. Read
out of `@google/genai` (`dist/index.mjs`, `Live.connect`) and confirmed against
a live session from this Swift client:

| | API key | Ephemeral token (`auth_tokens/…`) |
| --- | --- | --- |
| API version | `v1beta` | `v1alpha` |
| RPC | `…GenerativeService.BidiGenerateContent` | `…GenerativeService.BidiGenerateContentConstrained` |
| Credential | `?key=<key>` | `?access_token=<token>` |

("Constrained" is the token's `liveConnectConstraints`.) The desktop now bakes
the whole session into the token — model, voice, transcription, system
instruction **and the Hermes tool declarations** — and that config *replaces*
whatever the client sends in `setup`. So in paired mode the phone sends nothing
but the model name (`LiveClient.Config.minimalSetup`) and relies on none of it:
it just answers the tool calls. The Voice field is therefore gone from the
paired UI and kept only for the unpaired developer fallback, where the client's
own `setup` is still what counts.

Tokens are minted with `uses: 1` and a 60 s window in which to start a session,
so the app fetches one immediately before each connect and never stores or
reuses it. A refused token is **not** rejected at the handshake: the socket
opens and is then closed with code **1011** and a reason such as
`Token has been used too many times`. `LiveClient` treats a 1011 close — or any
server close before `setupComplete` within 2 s — as `authorizationFailed`, which
the UI reports as an authorization problem and never retries blindly.

## Files

| File | What it does |
| --- | --- |
| `Sources/LiveClient.swift` | Foundation-only actor: connect, `setup`, `realtimeInput` audio, `clientContent` text, parse server frames, emit an `AsyncStream<LiveEvent>`. Compiles for iOS **and** macOS. |
| `Sources/AudioEngine.swift` | `AVAudioSession` + `AVAudioEngine`: mic tap → `AVAudioConverter` → 40 ms 16 kHz Int16 chunks; `AVAudioPlayerNode` playback of 24 kHz PCM16; `flushPlayback()` for barge-in. Rebuilds the whole graph on route/configuration changes (Bluetooth) and publishes an `AudioStatus` snapshot. iOS only. |
| `Sources/LinkClient.swift` | Foundation + CryptoKit: strict `iris-link://pair` deep-link parsing, the six-digit code derivation (same as `electron/pairingStore.mjs`), and the async client for `/link/pair`, `/link/status`, `/link/gemini-token`. Compiles for iOS **and** macOS. |
| `Sources/LinkTasks.swift` | The task half of Iris Link (`LINK_API.md` §4): dispatch, list, status, result, stop, approval, announced — with every documented error code as a typed `LinkError`. Defines `LinkTaskService`, the seam the tool router is tested against. |
| `Sources/DispatchGate.swift` | Pure-value port of `electron/hermesGate.mjs` (`LINK_API.md` §6): one proposal at a time, read-back → user turn → claim, the same rejection reasons, a 5-minute TTL. Plus `ApprovalGate`, the same ordering rule for `approve_hermes_action`. No I/O, no clock of its own. |
| `Sources/ToolRouter.swift` | Executes the eight declared tools and returns *exactly* the JSON of `LINK_API.md` §5, `instructions` strings verbatim. Also `HermesBrief.format` (a port of the desktop's `formatHermesBrief`) and the `SYSTEM_EVENT_*` templates. |
| `Sources/SessionCoordinator.swift` | Turns Live events into gate transitions, runs tool calls off the audio path, polls active runs on the contract's 2 s cadence with backoff, injects `SYSTEM_EVENT_SESSION_START` and `SYSTEM_EVENT_HERMES_COMPLETE`, and calls `announced` only after the announcement turn completes. Foundation-only. |
| `Sources/RunsView.swift` | The run list (including desktop-dispatched runs), stop, and the raw stored result. Also the quiet background poll that watches for completions while no session is live. |
| `Sources/RunNotifier.swift` | Local notifications for this phone's completed runs, with an honest note about what iOS delivers without push. |
| `Sources/KeychainStore.swift` | The pairing (host, port, device id, credential) and the fallback API key, both `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never logged. |
| `Sources/ContentView.swift` | SwiftUI harness: paired card / pairing sheet, developer-fallback key field, Start/Stop, status dot, the pending-proposal indicator, the runs section, rolling transcript, error line, and a collapsed Debug group holding the route/engine lines and the tool log. |
| `Sources/IrisLivePrototypeApp.swift` | `@main` app entry. |
| `Tools/main.swift` | macOS CLI probe — reuses `LiveClient.swift`, reads the key from `~/.iris/.env`, sends one text turn, counts audio bytes. |
| `Tools/run-probe.sh` | Builds and runs the probe. |
| `Tools/LinkProbe/main.swift` | macOS CLI probe for the *pairing* path — reuses `LinkClient.swift` and `LiveClient.swift` to derive a code, pair, call status, mint a token through Link, open a Live session with it, and show what a reused token and a revoked credential look like. |
| `Tools/run-link-probe.sh` | Builds that probe. |
| `Tools/ConversationProbe/main.swift` | macOS CLI probe for the *dispatch* path — reuses `LiveClient`, `LinkClient`, `DispatchGate`, `ToolRouter` and `SessionCoordinator` to hold a real text conversation on a real ephemeral token and show the gate, the dispatch and the announcement. |
| `Tools/run-conversation-probe.sh` | Builds that probe. |
| `Tools/linkHarness.mjs` | Throwaway Node harness for the probe: the **real** `electron/irisLinkServer.mjs`, `electron/pairingStore.mjs` and `electron/mobileSession.mjs` on 127.0.0.1, with **fake** task handlers so nothing reaches Hermes. |
| `Tests/` | XCTest target: the gate against every case in `test/hermesGate.test.mjs` plus the contract's extra orderings, and every tool result shape against `LINK_API.md`. |
| `project.yml` | XcodeGen spec (bundle id `app.iris.liveprototype`, iOS 18, Swift 5 mode, the `iris-link` URL scheme). |

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
3. Pair the phone (below). While unpaired you can still paste a Gemini API key
   under **Developer fallback: API key**; a paired phone never uses it.
4. Tap **Start**, accept the microphone prompt.

`xcodegen generate` is only needed after editing `project.yml` or adding files.

## Pairing with the Iris desktop

Both ends have to be running for this:

- The desktop app runs **from source** with Iris Link enabled
  (`electron/main.mjs` starts it and binds *only* the Mac's Tailscale address —
  nothing on loopback or the LAN can reach it).
- **Tailscale is up on both devices**, and the Mac has a 100.x address. Without
  it the desktop refuses to show a QR code and the phone has nothing to reach.

Then:

1. On the Mac, open Iris → **Pair a device**. It shows a QR code and a six-digit
   code. The offer lasts **120 seconds** and can be used **once**.
2. Open the iPhone **Camera** app and point it at the QR code. The payload is an
   `iris-link://pair?…` deep link, so the Camera offers to open Iris Live
   directly — it never offers to web-search the pairing secret.
3. The app shows a confirmation sheet with the Mac's name, its address, and
   **its own six digits**, computed on the phone from the scanned secret.
   **Compare them with the code on the Mac.** If they differ, do not pair.
4. Tap **Pair**. The phone sends the secret once, receives its own device
   credential, and stores it in the Keychain
   (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). The secret is never shown,
   logged, or written anywhere.

After that the main screen shows the paired Mac, its address, and whether the
agent is reachable. **Unpair this phone** deletes the local credential; to cut
it off from the Mac's side as well, revoke the device in Iris on the desktop.

### What the errors mean

| What you see | What happened |
| --- | --- |
| "…points at *x.y.z.w*, which is not a Tailscale address" | The QR did not carry a 100.64.0.0/10 address. The app refuses any other host, so a QR code from an untrusted source cannot aim it at someone else's server. |
| "This pairing code is version *n*" | Desktop and phone disagree on the payload version. Update one. |
| "That pairing code expired" (`offer_expired`) | More than 120 s passed. Show a fresh code. |
| "That pairing code was already used" (`offer_used`) | A device already redeemed it. Offers are single use. |
| "Your Mac is not offering this pairing code any more" (`offer_unknown`) | The desktop replaced or cleared the offer (showing a new QR invalidates the old one). |
| "Too many pairing attempts" (`too_many_attempts`, `rate_limited`) | Five bad secrets burn the offer; ten pair attempts a minute are rate limited. Wait, then show a fresh code. |
| "Could not reach Iris on your Mac…" | Transport failure: tailnet down, Mac asleep, Iris not running. Explicitly *not* a refusal. |
| "This phone is no longer paired with your Mac" (`not_paired`) | The credential was revoked or is unknown. The app deletes it and returns to the pairing screen. |
| "Your Mac could not issue a Gemini session token" (`token_unavailable`) | Iris Link is up but minting failed — usually no `GEMINI_API_KEY` configured on the desktop. |
| "Gemini refused this session's token (close 1011…)" | The token was expired, already used, or outside its 60 s start window. Tap Start to ask for a fresh one. |

Visiting any Iris Link URL in a browser returns `{"error":"not_paired"}` — that
is the service working: everything except `POST /link/pair` requires a device
credential.

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

## Pairing probe (no phone needed)

```bash
./Tools/run-link-probe.sh          # builds ./.build/linkprobe
```

The probe reuses the app's own `LinkClient.swift` and `LiveClient.swift`. Drive
it against a real Iris Link server (`electron/irisLinkServer.mjs` +
`electron/pairingStore.mjs` with a temp devices file on 127.0.0.1) and it will
show, in order: the Swift-derived six-digit code, a successful pair, a refused
second redemption of the same secret, `/link/status`, a token fetched through
Link opening a Live session, the same token refused with close 1011, and a
revoked credential coming back as `not_paired`.

Subcommands: `code`, `parse-strict`, `pair`, `status`, `live`, `reuse`. Only the
probe may parse a deep link whose host is outside 100.64.0.0/10, through an
explicit argument the app never passes.

## End-to-end dispatch probe (no phone needed)

Runs a real Live session on a real ephemeral token against a real Iris Link
server whose task handlers are fakes, so no Hermes work is dispatched.

```bash
./Tools/run-conversation-probe.sh                 # builds ./.build/conversationprobe

# terminal 1 — the harness (GEMINI_API_KEY is read from ~/.iris/.env, never printed)
SCRATCH=/tmp/iris-probe PORT=8799 COMPLETE_AFTER_MS=25000 node Tools/linkHarness.mjs

# terminal 2
./.build/conversationprobe pair "$(cat /tmp/iris-probe/deeplink.txt)" /tmp/iris-probe/cred.json
./.build/conversationprobe confirm /tmp/iris-probe/cred.json   # propose → blocked submit → confirmed submit → status → completion
./.build/conversationprobe decline /tmp/iris-probe/cred.json   # decline → discard, nothing dispatched
```

`confirm` costs one Live connect, `decline` one more. Watch the harness output:
`DISPATCH_RECEIVED` must appear exactly once, carrying the exact staged brief,
and only after the confirmation turn. `ANNOUNCED_ACK` must appear only after the
announcement turn finished.

## Unit tests

```bash
xcrun simctl list devices available | grep iPhone
xcodebuild test -project IrisLivePrototype.xcodeproj -scheme IrisLivePrototype \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Device test script: Hermes from your pocket

The one that matters. Phone paired, Iris and Hermes running on the Mac,
AirPods in (or the phone on a desk on speaker).

1. **Start** the session. Iris greets you once.
2. Ask for something small and real, naming Hermes:
   *"Ask Hermes to count the files in my Downloads folder and tell me which one
   is the largest."*
3. **Hear the read-back.** Iris repeats the brief in a sentence or two and asks
   whether to send it. The orange **"Waiting for your answer — nothing sent
   yet"** card appears with the exact brief. Nothing has left the phone.
4. **Confirm by voice** — "yes", "go ahead", "send it", whatever is natural.
   The gate does not match words; Iris interprets you.
5. **Look at the Mac.** A task card appears there within a second or two.
6. Keep talking while it runs. Ask *"how's that going?"* — Iris must say it is
   still working and nothing more.
7. **Hear the result announced** on the phone when Hermes finishes, without
   asking for it.
8. **Open the run** in the Hermes runs list and read the full stored output.

### The negative test — run this every time

1. Ask for something you do *not* want done:
   *"Ask Hermes to delete everything in my Downloads folder."*
2. Wait for the read-back.
3. **Say no** — "no", "forget it", "don't send that".
4. **Nothing must be dispatched.** No task card on the Mac, no new row in the
   runs list, and the pending-proposal card disappears.

Also worth doing once: interrupt Iris *during* the read-back and then say
"yes". The submit must be refused and Iris must stage and read the brief again
— a brief you talked over was not a brief you heard.

### What the phone cannot do, and says so

- A Hermes clarification, a sudo password or any secret: Iris says it needs
  attention on the Mac. There is no transport for those (`LINK_API.md` §4).
- A dangerous-command approval *can* be resolved from the phone, but only after
  Iris describes it, ends its turn, and you answer in a turn of your own.
- If the Mac is unreachable the app says so; if the Mac is up but Hermes is
  not, it says *that* instead. They are different sentences on purpose.

## Device test script: pairing

1. **Pair** — follow the steps above. Confirm the six digits on the phone match
   the Mac before tapping Pair.
2. **Start with no key** — make sure the API-key field is empty (it is hidden
   while paired anyway) and tap **Start**. The status line should read
   "Getting a token from your Mac…", then "Connecting…", then "Live". Say
   *"Hello, can you hear me?"* and confirm you get a spoken answer. Nothing on
   the phone holds a Gemini key.
3. **Revoke from the desktop** — with the session stopped, revoke this device in
   Iris on the Mac, then tap **Start** again. Expect: "This phone is no longer
   paired with your Mac. Pair it again from Iris on the desktop.", the paired
   card replaced by the pairing screen, and no session started. It must not look
   like a network error or an empty result.
4. **Unpair locally** — pair again, then tap **Unpair this phone** and confirm.
   The card disappears and the developer-fallback field returns.

Report: the two codes you compared, what the status line said at each step, the
exact wording of any error, and whether step 3 ever looked like a network
failure.

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

## App Transport Security and the local-network prompt

Iris Link is plain HTTP to a Tailscale IPv4 literal (`http://100.x.y.z:port`),
inside WireGuard. Two Apple policies could have applied, and neither needs a
blanket exception:

- **ATS** does not apply here at all. Apple's rule is that "App Transport
  Security (ATS) applies only to connections made to public host names", and the
  system does not provide ATS protection to connections made to IP addresses;
  Apple's DTS adds that on iOS 10 and later such loads are always allowed, and
  that `NSAllowsLocalNetworking` affects unqualified and `.local` *host names*,
  not IP literals. So this app ships **no `NSAppTransportSecurity` dictionary at
  all** — narrower than `NSAllowsLocalNetworking`, and far narrower than
  `NSAllowsArbitraryLoads`, which is never set. *High confidence, and cheap to
  falsify: an unpaired phone that cannot reach the Mac would fail here first.*
- **Local network privacy** covers devices on the *immediate* network. A tailnet
  peer is reached over the `utun` tunnel interface, not the local link, so the
  prompt is not expected. Apple's documentation does not state that negative
  explicitly, so `NSLocalNetworkUsageDescription` is declared anyway with an
  honest string: if iOS ever does classify a tailnet peer as local, the
  alternative is a silent connection failure. *Medium confidence on the "not
  expected" half; the declaration costs nothing and cannot cause a prompt on its
  own.*

Both need a real device on a real tailnet to confirm — the simulator and the
CLI probe cannot exercise either policy.
