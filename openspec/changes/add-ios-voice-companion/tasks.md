## 1. Prototypes that can invalidate the design

- [x] 1.1 Prove a Swift `URLSessionWebSocketTask` client can open a Gemini Live session, stream 16 kHz PCM up, and play 24 kHz PCM back — verify by holding a 30-second spoken exchange from a throwaway iOS app
- [x] 1.2 Mint an ephemeral token (`AuthTokenService.CreateToken`) from a script and connect the prototype with it instead of an API key — verify the session opens with the token and is refused after expiry
- [x] 1.3 Reach a stub service bound to the Mac's Tailscale address from the iPhone — verify it answers over the tailnet, is refused without a credential, and is unreachable from a non-tailnet network
- [ ] 1.4 Prototype `StartIrisSessionIntent` with `openAppWhenRun = true` and time "Hey Siri" → microphone live — verify capture starts and record whether the launch feels like an assistant or an app launch
- [ ] 1.5 Prototype a question-shaped Siri phrase ("ask Iris to research X") and verify whether the string reaches the intent or Siri answers it itself; if intercepted, settle on imperative phrasing before any UI work

## 2. Desktop: pairing and token service

- [x] 2.1 Add the Iris Link service to the Electron app, bound to the Tailscale address only, with a token endpoint that mints Gemini ephemeral tokens for a paired device — verify a paired client receives a token, an unpaired request is refused, and the port does not listen on other interfaces
- [x] 2.2 Implement per-device credential issuance and storage on the desktop — verify two paired devices receive distinct credentials
- [x] 2.3 Add the "Pair a device" panel with a QR code carrying a one-time, short-lived payload — verify the payload expires unused and cannot pair a second device
- [x] 2.4 Add the paired-device list with names, last-seen times, and revoke — verify a revoked credential is refused on its next request
- [x] 2.5 Write unit tests for pairing issue/expire/revoke in `test/` alongside the existing suites — verify `npm test` covers the refusal paths
- [ ] 2.6 Rate-limit authenticated Iris Link routes per device (token minting and run creation especially) and keep a per-device audit log of dispatched runs — verify a burst beyond the limit is refused with a distinct error and that a dispatched run appears in the log with its device id — _Partly done: pairing and `POST /link/sessions/new` are rate-limited (429 `rate_limited`). Token minting and run creation are not, and there is no per-device audit log yet._ (#7)
- [ ] 2.7 Serve Iris Link over HTTPS on the Mac's MagicDNS name with a `tailscale cert` certificate, put that hostname in the pairing QR, and have the phone accept only `*.ts.net` hosts — verify the iOS app pairs and fetches a token with no App Transport Security exception in its Info.plist
- [x] 2.8 Report which desktop build the phone is talking to: `/link/status` carries a build stamp (short commit, dirty flag, version, process start time) and the phone shows it first in Settings → Debug, because the Electron main process does not hot-reload — verify the stamp changes after a restart on a new commit (f63660f)

## 3. Hermes reachability

- [x] 3.1 Add the Hermes proxy to Iris Link: forward only the allowlisted routes (runs, status, events stream, stored results, interaction responses, sessions) to loopback Hermes with the shared key attached server-side — verify an allowlisted call succeeds, a non-allowlisted path is refused, and the shared key never appears in any response
- [ ] 3.2 Document a Tailscale ACL restricting the Iris Link port to the user's own devices — verify a tailnet node outside the ACL is refused
- [ ] 3.3 Add a preflight check to the iOS app that distinguishes "tailnet down", "host asleep", and "service not running" — verify each produces its own message — _Not done: the phone still reports one `unreachable` outcome for all three. It does separately distinguish “Mac reachable, Hermes not” from `/link/status`._

## 4. iOS: session core

- [ ] 4.1 Create the SwiftUI app target with microphone and notification permission flows — verify a refused permission shows the explanation path, not a broken session — _App target, microphone prompt and the notification permission flow with a Settings link exist. The refused-microphone explanation path has not been verified._
- [x] 4.2 Implement pairing on the phone: register the `iris-link://` scheme, redeem a scanned offer with Iris Link, show the 6-digit code for comparison, and store the device credential in the Keychain — verify scanning the desktop QR opens the app, the device appears in the desktop list, and a revoked device returns to the pairing screen
- [x] 4.3 Connect with an ephemeral token fetched from Iris Link instead of an API key — verify a full spoken session with no Gemini API key on the phone, and that an early 1011 close is reported as not authorized
- [x] 4.4 Implement the Live WebSocket client (setup, realtime input, server content, transcripts, tool calls, session resumption) — verify against the prototype's recorded message flow — _LiveClient.swift; measured against the live API in 9d7953a and 759a0a5_
- [x] 4.5 Implement capture and playback with `.playAndRecord`, echo cancellation, and barge-in flush — verify playback stops within a perceptibly immediate interval when the user speaks over it — _Echo cancellation verified on an iPhone loudspeaker (450b257); see 4.12 for the self-interruption fix_
- [ ] 4.6 Handle route changes and interruptions — verify a headset connect mid-session and an incoming call each behave as `ios-voice-companion` specifies — _Route changes are handled and were device-tested with AirPods (450b257), and an interruption handler exists. The incoming-call scenario has not been verified._
- [x] 4.7 Add `UIBackgroundModes: audio` and lock-screen controls — verify a session survives locking and can be ended from the lock screen — _verified on an iPhone (f4de66e); idle auto-end split out as 4.9_
- [x] 4.8 Implement reconnect with session resumption, and an explicit "started a fresh conversation" message when resumption fails — verify by killing the network mid-session — _759a0a5. Measured, not assumed: a phone cannot present a resume handle itself, so it is baked into a freshly minted token; 1011 under a working session means reconnect, not refusal_
- [ ] 4.9 Idle auto-end: a session with no speech for a set time ends itself and says so — verify an abandoned session closes and releases the microphone (split from 4.7; not built)
- [x] 4.10 Replace the probe screen with the real app: a voice orb that is the start/stop control, a plain-language status line, a transcript, a floating control bar (route picker, Runs, Settings), and a Settings screen; Liquid Glass only on the control layer, with a material fallback before iOS 26 — verify with UI tests that tap the controls, after glass was found swallowing taps on device (345d6a2)
- [x] 4.11 Keep a pending question on screen across Gemini's ten-minute reconnect: carry the staged brief over as `readback_interrupted`, so the model's own submit is still refused but a tap still confirms; hold completion announcements while a question is pending — verify a reconnect never upgrades an unconfirmed proposal and never drops one the user is reading (355f3b6)
- [x] 4.12 Stop Iris interrupting herself on the loudspeaker: low start-of-speech sensitivity with a short required run of speech, baked into the phone token — verify the config is accepted in a constrained token and that a person speaking over her still interrupts (18d96f5)
- [x] 4.13 Tell every session the local time, date and zone, with today/tomorrow/yesterday spelled out; the phone sends its own IANA zone with every token request, validated on the Mac — verify by replaying 9 pm Eastern on a Sunday: the brief reads “tomorrow, Monday” not Tuesday (210a064)

## 5. iOS: agent work

- [x] 5.1 Implement the dispatch gate as a Swift value type mirroring `hermesGate.mjs` — verify unit tests reject same-turn dispatch, allow confirmed dispatch, and handle decline and amend
- [x] 5.2 Implement the Hermes client (dispatch, run status, stored results, interaction responses) against the pinned session — verify a task dispatched from the phone appears in the same session as desktop runs
- [x] 5.3 Wire the Live tool declarations to the gate and Hermes client — verify a full voice round trip: request, read-back, confirmation, dispatch, "it started"
- [x] 5.4 Implement run list and result reading, including runs dispatched elsewhere — verify a desktop-dispatched result can be opened and read on the phone
- [x] 5.5 Implement local completion notifications raised on reconnect — verify a run finishing with the app closed produces a notification that deep-links to the result — _Local notifications in 9d7953a, tap-to-run routing in 36b3dd9. The app-closed case is delivered by push (5.9), since local notifications only fire while the app is alive_
- [ ] 5.6 Implement the secure input surface for credential requests from a run — verify a secret prompt never appears in the transcript or is spoken
- [ ] 5.7 Reconcile `LINK_API.md` with the desktop where the phone implementer found them disagreeing: the barge-in rule (desktop accepts a read-back interrupted after 48 audible characters; the contract says any interruption invalidates it) and the missing `allowDuringReadback` equivalent — verify the contract, the desktop, and the Swift gate state one rule and share test cases for it
- [x] 5.8 Expose pending approvals to the phone (a field on task status or an undelivered-style list) so an approval can be surfaced rather than only answered — verify a run awaiting approval shows as such on the phone and that approving still requires a user turn — _`pending_approval` on task status (ed96b7b); “Hermes is waiting for you” card with explicit tap and restated command (36b3dd9)_
- [x] 5.9 Send push notifications from the desktop through APNs (token-based auth with the team's .p8 key, no third-party relay): the phone registers its device token and environment with Iris Link; the desktop pushes when a phone-dispatched run finishes and when a run is waiting on the user — verify a notification arrives with the app closed and the phone locked, that opening it shows that run, and that a revoked device stops receiving pushes — _Desktop ed96b7b, phone 36b3dd9. Pushes were observed arriving on the device (the crash fixed in 36b3dd9 only happened when one did). That a revoked device stops receiving them has not been re-verified on a device_
- [ ] 5.10 Deliver files from a finished run to the phone: surface the files a run produced (Hermes reports them as `MEDIA:<path>` lines in its result) as attachments on the task API, serve each one over Iris Link to the paired device only, and let the run screen preview, save to Files, or share it — verify a PDF produced by a run opens on the phone, that a path outside the allowed locations is refused, and that a revoked device can no longer fetch it
- [ ] 5.11 Tell Hermes how to hand a file to the phone, so "send it to my phone" produces an attachment instead of a copy left in Downloads and a scripted Messages attempt — verify a spoken request for a file results in an attachment on the run and an honest spoken confirmation that names where it is
- [ ] 5.12 Optionally save a run's files into the configured Obsidian vault as a second destination, off unless a vault is set — verify file delivery over Iris Link works with no vault configured, that a vault copy lands in an attachments folder when one is, and that Iris never claims a file is on the phone on the strength of a sync she cannot observe
- [x] 5.13 Answer a staged proposal with large thumb-reach buttons — Yes (green), No (red), Let me explain (yellow) — mirrored for left-handed use from Settings, showing the complete brief they act on; Yes dispatches the staged brief directly and tells Iris it was sent — verify each button's outcome on a phone without speaking, that a tap during the read-back works, that the model cannot trigger them, and that a replaced brief cannot be confirmed by a stale tap — _76ad5a1; reconnect behaviour in 4.11_
- [x] 5.14 Answer a Hermes approval with the same large buttons: Approve (allow once) and Deny are a single tap with the complete request on screen, broader grants stay behind a confirmation, and the handedness setting applies — verify on a phone that an approval can be answered without speaking, that a stale request cannot be answered, and that the model still cannot approve anything by itself — _76ad5a1_
- [x] 5.15 Say why a run failed: classify Hermes' own failure text into a stable code with one plain sentence and a recovery hint (`session_in_use`, `backend_start_failed`, `model_unreachable`, `auth_failed`, `run_limit`, `gateway_unreachable`), carry it on the dispatch error, list, status, result, completion push and spoken event, and keep a sanitized first line for unknown failures — verify “not reachable” is only ever said when the gateway really is unreachable (d5d66c1; FailureDecodingTests)
- [x] 5.16 Recover from a chat locked by Hermes Desktop: `POST /link/sessions/new` creates and pins a fresh chat and may re-dispatch a run's exact brief, only for a failed run owned by the asking device that failed with `session_in_use`; one confirmed tap on the phone, no tool, so the model cannot trigger it — verify the refusals (`not_a_live_run`, `retry_not_allowed`) and that the desktop follows the repin (d5d66c1)
- [x] 5.17 Back off the interactive Hermes backend after repeated start failures, with a longer configurable start allowance, instead of respawning in a tight loop (d5d66c1)
- [ ] 5.18 Restart the desktop on d5d66c1 or later and confirm 5.15–5.17 from the phone — the Electron main process running during that work predates the commit, so the Mac side has only been verified by tests and against the real registry, not from a device

## 5a. Run progress and history

- [x] 5a.1 Expose live run progress over Iris Link: accumulate steps per run in the main process (`runSteps.mjs`, pinned to `src/lib/tasks.ts` by a parity test), redact previews, and serve `headline`, `step_count`, `steps` and a `steps_since` cursor — verify progress is never invented: no events means no steps, and `steps_complete` is false after a restart or eviction (49496c2)
- [x] 5a.2 Run detail screen on the phone mirroring the desktop card: status, brief, live headline with an indeterminate bar, step list with previews and ticking durations; polls only while visible and active; Stop moves to a swipe action and the toolbar (759a0a5)
- [x] 5a.3 Rebuild a finished run's steps from Hermes' saved transcript when memory has none, matched by brief and nearest timestamp, redacted, cached, with no invented durations — verified against the real transcript (b12ca20)
- [x] 5a.4 Make missing steps diagnosable: `steps_unavailable_reason` from the desktop, shown on the phone; and make `taskStatus(runId:stepsSince:)` a protocol requirement, because the extension default was being statically dispatched through the existential and the phone never asked for steps — regression test calls it through `any LinkTaskService` (f63660f, 086a473)
- [x] 5a.5 Show full run history: the phone's list uses the desktop's merge of registry and transcript-rebuilt runs, restored runs open read-only, and runs from previous chats appear under Earlier chats; history never reaches the notifier, the announcement queue or a Live Activity — verified against the real registry: 1 + 13 merges to 13, with 80 earlier runs (d5d66c1)

## 5b. Voice and accent

- [x] 5b.1 Desktop: English accent presets (British RP, Scottish, Irish, Australian, General American, or free text) steered by instruction, and all 30 Gemini voices with Google's descriptors (9ab23a1, 8adda8d)
- [x] 5b.2 Desktop: bind resume handles to the model, voice, accent and display name that issued them, so a changed voice starts a fresh session instead of resuming the old one (3117bd5)
- [x] 5b.3 Iris Link: `POST /link/gemini-token` takes an optional `voice` (validated against the catalogue) and a `purpose`; a `preview` token is single-use, two minutes, tool-free and context-free and speaks one sample line; `/link/status` lists the voices and the default — verified against the live API (0e05bc4; LINK_API.md §13)
- [x] 5b.4 Phone: voice picker in Settings with a Mac-default option and a per-voice preview on its own playback-only engine, so the tuned `.playAndRecord` session is never touched; the choice is sent with every token, including reconnect mints, and applies from the next conversation (36b3dd9)
- [x] 5b.5 Make the preview button usable: a 44 pt hit area (it was a 19 pt glyph 14 pt from the select button) and the “previews are off during a conversation” line moved above the rows, where the greyed buttons are — verify with a UI test that taps ▶ rather than asserting it exists; confirmed working on the phone (ff92ddf)

## 5c. Live Activity and widgets

- [x] 5c.1 Desktop: push Live Activity updates through APNs (`liveactivity` push type), one summary activity per device, coalesced to one update per eight seconds with a trailing flush, attention and end bypassing the window, a stale-date on every non-terminal push, and no percentage anywhere; `GET /link/summary` feeds the widget — verified against the APNs sandbox with the real key (3dc7fb5; LINK_API.md §14)
- [x] 5c.2 Phone: `IrisWidgets` extension with a Lock Screen / Dynamic Island Live Activity and Home Screen widgets; registers update and push-to-start tokens; widgets read a non-secret App Group snapshot and show its age; `iris://` deep-links into a run; `ContentState` dates are epoch seconds and the three example payloads are decoded verbatim in a test (99679cb)
- [ ] 5c.3 Verify on a locked phone that a pushed update moves the Live Activity while the app is suspended, that push-to-start works with the app not running, and that a stopped Mac leaves a visibly stale activity — sandbox acceptance is verified; delivery to a device is not recorded

## 6. Siri entry points

- [ ] 6.1 Ship `StartIrisSessionIntent` and `SendTaskToIrisIntent` with an `AppShortcutsProvider` — verify both appear in Shortcuts with no user setup and that phrases include the app name token
- [ ] 6.2 Add free-text handling with `requestValue` for a task with no inline parameter — verify the spoken string reaches the intent unchanged
- [ ] 6.3 Register the `iris://` URL scheme in the Electron app's `Info.plist` with wake and task actions — verify a macOS Shortcut using "Open URL" wakes the desktop app and dispatches a task
- [ ] 6.4 Document the macOS Swift helper app option and decide for or against it based on task 1.4's result — verify the decision is recorded in design.md before any helper code is written

## 7. Contract conformance

- [ ] 7.1 Turn `agent-dispatch-contract` scenarios into a shared checklist and run it against the desktop app — verify each scenario passes or is filed as a desktop follow-up
- [ ] 7.2 Run the same checklist against the iOS app — verify every scenario passes before the app is used for real work
- [ ] 7.3 Exercise the unreachable-agent paths end to end (Mac asleep, tailnet off, Hermes stopped) — verify no failure is ever reported as an empty or successful result

## 8. Distribution and follow-on

- [ ] 8.1 Set up Apple Developer provisioning and a TestFlight build — verify an install on the user's own devices from TestFlight — _Development provisioning works (the app runs on the user's iPhone). No TestFlight build yet._
- [ ] 8.2 Write the setup guide (pairing, Tailscale, Siri phrases, what to do when the Mac is asleep) — verify a clean install can be set up following it alone
- [ ] 8.3 Open the watchOS change proposal informed by what phases 1–7 learned — verify it names its transport and what it does when the phone is out of range
