## Context

See proposal.md — Why. What shapes the approach:

- **The desktop is the only implementation.** `electron/main.mjs` owns the Gemini Live session (`@google/genai`, `ai.live.connect()`), the tool declarations, the Hermes bridge (`POST /v1/runs`, status polling, SSE events), config from `~/.iris/.env`, and the dispatch gate in `electron/hermesGate.mjs`. The renderer captures 16 kHz PCM with WebRTC echo cancellation and plays 24 kHz PCM back.
- **Hermes is loopback by default.** Its API binds `127.0.0.1:8642`; `API_SERVER_HOST` can be changed, and every request needs `API_SERVER_KEY`. The docs are blunt that this endpoint gives "full access to hermes-agent's toolset, **including terminal commands**", so anything that widens its reach is a security decision, not a convenience one.
- **The Live API is a WebSocket protocol** (`BidiGenerateContent`) with official SDKs for Python, JS/TS, Go, Java, and C# — **no Swift SDK**. It also issues **ephemeral tokens** (`AuthTokenService.CreateToken`, ~30 min for a live session, 60 s to start a new one, usage-limited) explicitly for client-side use.
- **Hermes already has mobile reach** through Telegram/WhatsApp channels. Those work when the phone has no other path, and are the honest fallback for text-only interaction — the iOS app must beat them at voice, not duplicate them at text.

## Goals / Non-Goals

**Goals:**

- One place where the dispatch contract lives conceptually, with the phone implementing the same behavior as the desktop rather than a looser version of it.
- Voice on the phone that works away from the Mac when the Mac is reachable, and degrades honestly when it is not.
- No long-lived Gemini API key on the phone.
- A transport that a watchOS client can sit behind later without redesign.

**Non-Goals:**

- Shipping a watchOS target in this change.
- Porting the Deck, Glass HUD, Neural Map, hand gestures, or the on-device wake word to iOS. The phone's entry point is deliberate (button, lock-screen control, Siri), not ambient listening.
- Running Hermes on the phone.
- Replacing the desktop app or changing its behavior.
- App Store distribution in phase 1 (TestFlight/personal provisioning is enough to validate the design).

## Decisions

### 1. The phone runs its own Gemini Live session; Hermes is reached through a proxy in the Iris desktop app

**Chosen:** on-device Live session, authenticated with **ephemeral tokens** minted by the Iris desktop app; Hermes requests go to a small authenticated proxy inside the desktop app, reachable only over Tailscale, which forwards them to Hermes on loopback.

Alternatives:

- **Relay everything through the desktop's Electron app.** Simplest key story (nothing leaves the Mac) and it reuses the existing tool router, but every phone conversation then requires the Mac awake and online, and it puts a realtime audio relay inside an Electron main process that already carries the desktop session. It also makes the watch a client of a client.
- **Direct to Gemini with a long-lived API key on the device.** Fewest moving parts, worst failure mode: a key in a mobile keychain with no revocation story beyond rotating it for every client.
- **Direct to Hermes without a mesh** (public ingress, port forwarding). Rejected outright — this endpoint runs terminal commands.

**Tailscale is the mesh, and Hermes never leaves loopback.** Hermes supports exactly one `API_SERVER_KEY`, so it cannot issue or revoke per-device credentials itself (found during apply; the original draft assumed it could). The Iris desktop app therefore runs one small HTTP service — *Iris Link* — bound to the Mac's Tailscale address only. It authenticates each request with that device's own credential, mints Gemini tokens, and forwards an allowlisted set of Hermes routes (runs, run status and events, stored results, interaction responses, sessions) to `127.0.0.1:8642`, attaching the shared key itself. The shared key never reaches the phone, `API_SERVER_HOST` is never changed, and revoking a phone is a local list edit. Tailscale ACLs still restrict which nodes may reach the Link port. If the tailnet is down the phone says so rather than falling back to anything weaker, which is what `client-pairing` requires.

Also rejected: **handing the phone the shared key** (works with the desktop app closed, but revoking one lost phone means rotating the key for every client, and a terminal-capable key lives on a phone), and **a standalone proxy daemon** (same shape as Iris Link without needing the app open — a reasonable later step, more moving parts now).

Why the chosen option: ephemeral tokens exist precisely for untrusted clients, so the phone holds a credential that expires in minutes rather than a key that must be revoked. The conversation survives the Mac being asleep (the user can still talk to Iris; only dispatch is refused, which `ios-voice-companion` already specifies). Hermes access rides a mesh network that provides device identity and encryption without exposing a port, and the same token service is what a watch would later ask through its phone.

Cost: the Iris desktop app must be running both to mint tokens and to reach Hermes. Conversation still works without it for as long as a cached token lasts; dispatch does not, and the phone must say which of the two is unavailable. Audio never transits the Mac.

### 2. Swift talks to the Live API over a raw WebSocket

There is no Swift SDK. The app implements `BidiGenerateContent` over `URLSessionWebSocketTask`: setup message, realtime input frames, server content with audio parts and transcripts, tool calls, and session resumption updates. The desktop's message handling in `main.mjs` is the reference for which fields matter.

**Verified on device (task 1.1):** the prototype held a live spoken exchange on an iPhone through the built-in speaker and microphone. `AVAudioSession` in `.playAndRecord` / `.voiceChat` with voice processing enabled cancelled echo well enough that the assistant never interrupted itself, and responses had no noticeable lag. The same test exposed that a Bluetooth headset silences playback, because the prototype did not rebuild its audio graph when the route — and with it the hardware sample rate — changed. Route-change handling is therefore a requirement of the session core, not polish. Further device testing showed iOS lists connected AirPods as an available input but will not move a voice session onto them by preference alone — `setPreferredInput` is accepted and ignored, and `.defaultToSpeaker` pins the route to the loudspeaker. Selecting them in the system route picker (`AVRoutePickerView`) works immediately, and the graph rebuild then follows the 48 kHz → HFP change. The app therefore ships the route picker as a first-class control, chooses the loudspeaker explicitly when no headset is adopted, and never sets `.defaultToSpeaker`.

Alternative — embedding a JS runtime to reuse `@google/genai` — was rejected: it drags a second runtime into a battery-sensitive app to save a protocol client that is a few hundred lines.

### 3. Tool calls stay on the phone, not in a shared service

The Live session calls tools; the phone answers them, including the propose/submit gate and the Hermes HTTP calls. This keeps the model's tool loop local to the session that owns it. The gate's state machine (`awaiting_readback → awaiting_user → confirmable`) is reimplemented in Swift as a value type with the same rejection behavior, and is the natural first unit test.

### 4. Pairing is a QR code shown by the desktop

The desktop's Settings gains a "Pair a device" panel that shows a QR code containing a one-time, short-lived pairing payload (the desktop's mesh address, the token endpoint, and a pairing secret). The phone scans it, exchanges the secret for its own per-device credential, and stores that in the Keychain with `WhenUnlockedThisDeviceOnly`. The desktop keeps a list of paired devices with last-seen times and a revoke button, satisfying `client-pairing`.

**The QR encodes an app deep link (`iris-link://pair?…`), never bare text or JSON.** Found in testing: a phone camera that cannot open a QR's contents offers to web-search them, and the first payload — plain JSON — put a live pairing secret into a Google query. It was single-use, 120 seconds, and only valid against a tailnet-only service, so nothing was exposed in practice, but the format was wrong. A custom scheme gives the camera nothing to search, and once the iOS app registers the scheme a scan opens it directly.

Alternative — typing the Hermes URL and key into the phone — is what the desktop wizard does today and is exactly what the spec forbids.

### 5. Runs are observed over SSE, with polling as the fallback

Hermes exposes both an event stream and run status. The phone subscribes to the stream while foregrounded, and falls back to polling on resume — the same belt-and-braces pattern the desktop already uses, and the only way to keep the run list honest after the app has been suspended.

### 6. Completion notifications are local, triggered on reconnect

Phase 1 uses local notifications raised when the app regains contact and finds terminal runs it has not announced. No push infrastructure, no Apple Push certificate, no third-party relay. The trade-off is that a completion arrives when the app next has a live connection rather than instantly; push can be added later behind the same spec.

### 6a. Push comes from the Mac, directly to Apple

Decision 6's local notifications only fire while the app is alive, which in practice means during a voice session. A suspended app cannot poll, so "tell me when Hermes is done" needs real push. The desktop sends it: APNs token-based auth (an ES256 JWT signed with the team's `.p8` key, kept in `~/.iris` and never sent to a phone) over HTTP/2 straight to Apple. No relay service, no third party sees task text beyond Apple's delivery. The phone registers its device token and APNs environment (sandbox for Xcode builds, production for TestFlight) with Iris Link; tokens are stored per paired device and deleted on revoke or when Apple reports them invalid. Payloads carry the run id and a short title, not the result body — the phone fetches the result over Link when opened, so nothing sensitive sits in a notification that a lock screen can show. Verified during apply: the key authenticates against both APNs hosts.

### 6b. Files reach the phone through Iris Link, not around it

Observed in use: asked to send a PDF "to my phone", Hermes copied it to the Mac's Downloads folder, tried scripting Messages, and reported success — nothing reached the phone, because no path existed. Hermes already marks files it produced with `MEDIA:<path>` lines in its result, so the desktop can turn those into attachments on the task API and serve them to the paired device over Iris Link.

This is a file-read endpoint on a network service, so it is deliberately narrow. A file is served only if a finished run's own result named it, the run belongs to the pinned session, and the resolved real path (symlinks followed) sits inside an allowlist of locations — the run's workspace and the user's Downloads to begin with — and outside the protected paths Iris already keeps Hermes away from. The phone asks by run id and attachment index, never by path, so a client cannot request an arbitrary file. Size is capped, the content type is sniffed rather than trusted from the name, and the same bearer credential and revocation apply as everywhere else. Attachments are listed on the run (name, size, type) but fetched only when the user taps one.

The model's side matters as much: the mobile prompt tells Iris that a file is handed over by Hermes naming it in its result, and that she must say where it is — "it's on the run in your Runs list" — rather than claiming it was sent somewhere she cannot verify.

**Iris Link is the baseline; other destinations are optional extras.** An Obsidian vault is an obvious second route — Iris already knows the vault path from the brain feature, and Obsidian Sync would carry a saved file to the phone even when the Mac is unreachable, where notes can link to it. It cannot be the only route: it needs Obsidian, a Sync subscription, and the mobile app open to pull, and Iris cannot observe whether the sync happened. So delivery over Link must work for someone who has never heard of Obsidian, a vault copy is offered only when a vault is configured, and what Iris says follows what she can verify — "it's on the run in your Runs list" for Link, "I saved a copy to your vault" for Obsidian, never "it's on your phone" on the strength of a sync she cannot see.

### 6c. The token, not the phone, defines the session — so voice, resumption and time zone all travel through the mint

Measured on device and against the live API: with `lockAdditionalFields` unset, an ephemeral token's config *replaces* the client's setup frame. A phone that sent its own voice and prompt got the default voice answering in a guessed language. That is the behaviour we want — the desktop decides who Iris is — but it means anything the phone legitimately chooses has to be a parameter of `POST /link/gemini-token` and be baked in on the Mac: `voice` (validated against the catalogue, never passed through raw), `resume_handle` (a client-sent handle is silently ignored, so reconnects mint a fresh token carrying it), and `timezone` (validated with `Intl`; the phone may be somewhere the Mac is not). The phone sends a setup frame containing the model and nothing else, so nobody is misled into thinking it controls more.

Voice previews use the same door with `purpose: "preview"`: single-use, two minutes, no tools, no personal context, one fixed sample line. Two Live connections would fight over one audio session, so a preview is refused while a conversation is live, and it plays through its own playback-only engine rather than the full-duplex graph whose routing was tuned on a device and is deliberately left alone. The UI has to say *why* the buttons are off, next to the buttons — the first build put that line below a 30-row list, and the feature read as broken.

A related measurement: close code 1011 is not always a refusal. A token's `expireTime` closes a healthy session with 1011 too, so 1011 before the session is usable means a refused credential and is never retried, while 1011 under a working session means reconnect on a fresh token.

### 6d. Progress is reported, never invented

Hermes reports tool calls, not a percentage, so nothing on the phone shows one — not the run screen, not the Live Activity. No events means no steps; `steps_complete` is false after a desktop restart or an eviction rather than implying the run did nothing; durations rebuilt from a transcript stay null because the transcript has none. Live Activity updates are coalesced to one per eight seconds to stay inside Apple's budget, a run needing the user bypasses the window, and every non-terminal push carries a stale date so a Mac that stops reporting leaves an activity that visibly goes stale instead of claiming work continues. `ContentState` dates are epoch seconds, because ActivityKit decodes with default strategies and a `Date` would silently land decades off.

### 6e. A failure names its cause, and recovery is a tap the model cannot make

Every failure used to reach the phone as “Hermes is not reachable from your Mac”, even with a healthy gateway. The desktop now classifies Hermes' own text into a stable code with one plain sentence and a recovery hint, and `gateway_unreachable` is the only code allowed to say unreachable. Unknown failures keep a sanitized first line rather than being dropped. The one recovery offered — starting a fresh chat when the pinned one is open in Hermes Desktop, and re-sending that run's exact brief — is an HTTP route with no tool behind it, limited to a failed run owned by the asking device that failed for that reason, and confirmed by the user. It follows the same rule as the answer buttons: a deliberate tap on a surface showing the whole brief is a confirmation; nothing the model emits can reach it.

### 7. Siri and Shortcuts are an entry point, not a second voice channel

Siri can start Iris and hand it a line of text. It cannot hand over the conversation. Apple's speech pipeline delivers a transcribed `String` to an `AppIntent`; no App Intents or SiriKit API hands a third-party app the live microphone stream (an absence-of-API finding — Apple documents no such mechanism rather than stating the negative). So the design treats Siri as an *ignition key*: "Hey Siri, start an Iris session" or "Hey Siri, send a task to Iris", after which Iris's own Live session owns the microphone.

**On iOS** the app hosts the intents natively:

- `StartIrisSessionIntent` and `SendTaskToIrisIntent`, exposed through an `AppShortcutsProvider` so they work with no user setup. Every phrase must contain the `\(.applicationName)` token, and a phrase may inline at most one parameter — e.g. `"Send \(.$task) to \(.applicationName)"`.
- Free text arrives as a `String` parameter, prompted with `requestValue` when the phrase omits it.
- **Starting capture requires the foreground.** iOS does not let an app activate a recording session from the background; an already-active session may continue backgrounded with `UIBackgroundModes: audio` and an `AVAudioSession` in `.playAndRecord`. So `StartIrisSessionIntent` sets `openAppWhenRun = true` (or continues via `ForegroundContinuableIntent`) and Iris launches into a live session. `SendTaskToIrisIntent`, which needs no microphone, can stay in the background and answer with `ProvidesDialog` + a snippet.
- Apple Intelligence's `AssistantIntent` schemas cover fixed domains (messaging, media, and so on); a general "research this" action has no matching schema and uses a plain custom intent.

**On macOS** the current app cannot host intents at all: App Intents is a Swift framework, and Electron has no bridge to it. Two options, and phase 1 takes the first:

1. **Custom URL scheme** (`iris://wake`, `iris://task?text=…`) registered in the app's `Info.plist`, invoked from a user-built Shortcut's "Open URL" action. Works today, needs no Apple Developer account and no App Store, and the user can voice-trigger it by naming the Shortcut. It does not give branded "Hey Siri, ask Iris…" phrases.
2. **A small signed Swift helper app** bundled alongside Iris that hosts the `AppShortcutsProvider` and calls the Electron app over localhost — the same shape as Iris's existing Hermes client. This is the only route to real Siri phrase discovery on macOS, at the cost of a second bundle, notarization, and Launch Services having seen it at least once.

**On the watch**, a Shortcut triggered on the wrist can relay to the paired iPhone, and Ultra's Action Button can run an App Intent directly — enough for "send this task", and it reinforces that dictation, not a live watch microphone session, is the phase 2 target.

Three claims here come from developer forums rather than Apple's reference docs and are cheap to disprove with a throwaway prototype before any of it is built: that Siri sometimes answers a question-shaped reply itself instead of passing the string to the app; that macOS App Intents discovery is unreliable for non-standard bundles; and the exact moment Launch Services registers a URL scheme. The first matters most, because "ask Iris to research X" is exactly the question-shaped phrasing at risk.

## Risks / Trade-offs

- **Iris Link is a new network-reachable door to a terminal-capable agent** → bound to the Tailscale interface only, per-device credentials with revocation, a route allowlist rather than a blanket forward, Tailscale ACLs on the port, and no public exposure under any option. Hermes itself stays on loopback. The allowlist and the bind address are the two lines that deserve review on their own.
- **A stolen unlocked phone inherits agent access** → device credential is Keychain-bound and revocable; the dispatch gate still requires a spoken confirmation for every task.
- **Background audio limits on iOS** → the session is user-initiated with a visible indicator and a lock-screen control; the spec already requires the app to report a platform-terminated session rather than pretend it survived.
- **Battery and thermals from a continuous 16 kHz upstream** → push-to-talk rather than ambient listening, idle auto-end, and no camera or gesture pipeline on mobile.
- **Two implementations of one contract drift** → `agent-dispatch-contract` is written as testable scenarios so both clients can be checked against it; drift found in the desktop is filed, not silently patched.
- **A refused ephemeral token looks like a successful connection** (verified in task 1.2: the socket is accepted, then closed with code 1011 and a reason such as "Token has been used too many times") → the Swift client treats an early 1011 close as an authorization failure, not a network blip, and does not retry it blindly.
- **Ephemeral tokens expire mid-conversation** → the client refreshes ahead of expiry and, failing that, reconnects with session resumption; the spec's "cannot be restored" scenario covers the visible outcome.
- **Apple developer account and device provisioning are a hard dependency** → phase 0 task, before any Swift is written.

- **iOS blocks plain HTTP to a Tailscale IP** (observed on device: error -1022, App Transport Security; ATS does apply to IP literals, contrary to older Apple guidance, and exception domains cannot name an IP range) → the prototype carries a blanket ATS exception so testing can proceed; the real app must not. Iris Link will serve HTTPS on the Mac's MagicDNS name using a `tailscale cert` certificate (this tailnet already has certificate domains enabled), the QR will carry that hostname, and the phone will accept only `*.ts.net` hosts. This also retires the no-TLS risk below.
- **A paired credential is a long-lived bearer token with no TLS beneath it but Tailscale's** → acceptable for the prototype because WireGuard encrypts the tailnet and Link binds to nothing else (verified: loopback and LAN connections are refused). Never enable Tailscale Funnel or a subnet route for the Link port. Credential expiry/rotation and request signing are deliberate follow-ups, not oversights.
- **A stolen credential could burn tokens or spawn agent runs at network speed** → per-device rate limits and a dispatch audit log (task 2.6); until then revocation is the only brake.
- **Hermes' non-approval prompts (clarify, sudo, secret) travel over its interactive WebSocket, not HTTP** (found while deriving the proxy allowlist) → the phone can answer approvals through Link but not those prompts. Phase 1 surfaces them as "needs attention on the desktop"; task 5.6's secure input surface depends on first extending Link to carry that transport.

## Migration Plan

Additive. No desktop behavior changes unless the pairing panel and token endpoint are added, and both are inert until first used. Rollback is deleting the app and revoking its device credential; the desktop keeps working with the pairing panel unused.

Sequencing: token/pairing service on the desktop → Swift Live client → gate and Hermes client → run list and results → notifications → watch phase (separate change).

## Open Questions

- Whether the iOS app lives in this repository or a sibling one. It shares no code with the Electron app, only the contract.
- Whether phase 2 (watch) talks to the phone or directly to the same services; the transport supports either, and the answer depends on how much the watch is expected to do with the phone out of range.
