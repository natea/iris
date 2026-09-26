## Why

Iris only runs as an Electron app on the desktop: the Gemini Live session, the Hermes bridge, wake word, gestures, and the Glass HUD all live in `electron/main.mjs` and `src/`, and the Hermes gateway it talks to listens on `http://127.0.0.1:8642`. The moments Iris is most useful — driving, walking, cooking, away from the desk — are exactly the moments the user cannot reach it. Today the only mobile path to Hermes is a text chat channel (Telegram/WhatsApp), which loses the voice loop, the confirmation gate, and the live task view that make Iris what it is.

An iPhone already has the microphone, speaker, network, and background audio support needed to run the same voice loop. This change proposes an iOS companion app as the first mobile surface, with an Apple Watch companion named as a follow-on phase so the architecture does not have to be redesigned to get there.

## What Changes

- **New iOS app** (SwiftUI, iOS 18+) that runs the Iris voice loop end to end: wake, converse with Gemini Live over a realtime audio stream, propose a Hermes task, confirm it by voice, watch it run, and hear the result announced.
- **Defined session ownership.** The proposal evaluates three placements for the Gemini Live session and the Hermes connection — on-device, relayed through the desktop app, or direct-to-Hermes over a private network — and design.md commits to one. This is the load-bearing decision for everything else.
- **A documented Iris client contract.** The behavior currently implicit in `electron/main.mjs` (dispatch gate, resume handles, announcement delivery, truthfulness rules) becomes a written capability that any client — desktop, iOS, later watchOS — must implement identically.
- **Credential and pairing flow for mobile.** The desktop reads `GEMINI_API_KEY` and `API_SERVER_KEY` from `~/.iris/.env`; a phone needs a pairing path that puts equivalent trust on the device (or avoids putting it there) without pasting keys by hand.
- **Reachability for Hermes off-LAN.** Hermes binds to loopback and has a single shared key, so the phone reaches it through a small authenticated proxy in the Iris desktop app, exposed only on the user's Tailscale network. Hermes itself is never exposed, and the Mac being asleep is an explicit failure mode.
- **Mobile-shaped interaction.** Push-to-talk and background audio instead of an always-listening wake word, a task list instead of the Deck/HUD, and notifications for completed Hermes runs.
- **Siri and Shortcuts entry points.** "Hey Siri, start an Iris session" on iOS via App Intents, and a URL-scheme-driven Shortcut on today's macOS app. Siri can start Iris and hand it a line of text; it cannot hand over the live microphone, so it is an ignition key rather than a second voice channel.
- **Added during implementation** — scope that device testing and daily use pulled in, none of it in the original plan. Each is tracked in tasks.md:
  - *Voice and accent.* The phone picks Iris's voice from the desktop's catalogue and can hear each one first, on a single-use, tool-free preview token. A token's config replaces the client's setup frame, so the desktop — not the phone — decides who Iris is; the phone only names a voice, and the desktop validates it. Accent presets and a fresh session on voice change came with it.
  - *Live run progress and history.* Step-by-step progress over Iris Link, a run detail screen that mirrors the desktop card, steps rebuilt from Hermes' transcript when memory has none, and the desktop's merged run history including earlier chats.
  - *Real push, then a Live Activity and widgets.* Local notifications turned out to fire only while the app is alive, so the desktop now pushes through APNs directly — completions, runs waiting on the user, and Live Activity updates for the Lock Screen and Dynamic Island — with Home Screen widgets fed from a non-secret snapshot.
  - *Answering without speaking.* Large thumb-reach buttons for a staged proposal and for a Hermes approval, with the contract requirement that makes a tap a valid confirmation and keeps it out of the model's reach.
  - *Failure reasons and recovery.* A failed run says why in one plain sentence instead of always “not reachable”, and a chat locked by Hermes Desktop can be replaced with a fresh one in a single confirmed tap.
  - *Conversation durability.* Reconnecting across Gemini's ten-minute connection reset on freshly minted tokens, keeping a pending question on screen across it, a loudspeaker self-interruption fix, and telling every session the user's local date and zone.
  - *Diagnosability.* A desktop build stamp on `/link/status`, because the Electron main process does not hot-reload and “did the Mac pick that up?” was otherwise a guess.
- **Apple Watch: out of scope for implementation, in scope for design.** The watch phase is specified as a thin client of the iOS app (dictate a task, see run status, hear the result) and the transport chosen here must not foreclose it.
- Not a change to desktop behavior. No **BREAKING** changes to existing capabilities; the desktop app keeps working exactly as it does now.

## Capabilities

### New Capabilities
- `mobile/ios-voice-companion`: the iOS app itself — voice session lifecycle (start, interrupt, background, end), push-to-talk and audio routing, task list and result reading, notification of completed runs, and offline/unreachable behavior.
- `mobile/client-pairing`: how a mobile client is authorized — pairing with the desktop or with Hermes, what secrets land on the device, how they are stored (Keychain), revocation, and what happens when pairing is missing or rejected.
- `agent-dispatch-contract`: the client-independent rules every Iris client must honor — the two-step propose/confirm gate, never inventing Hermes results, one pinned Hermes session, and how completed runs are announced. Extracted from current desktop behavior so iOS and watchOS inherit it rather than reimplementing it.

### Modified Capabilities
- None. The desktop app is the reference implementation of `agent-dispatch-contract` and is expected to already satisfy it; any drift found while writing that spec is recorded as a follow-up, not silently changed here.

## Impact

- **New code**: a Swift/SwiftUI app target (new repository directory or sibling repo — decided in design.md), plus a shared description of the client contract under `openspec/specs/`.
- **Existing code**: the desktop app gains a pairing panel and a small network service (token minting plus an allowlisted Hermes proxy) that is off until a device is paired; existing desktop behavior is otherwise untouched. `electron/hermesClient.mjs`, `hermesGate.mjs`, and the Live session lifecycle are the behavioral reference for the new specs.
- **Hermes**: depends on its HTTP API (`/v1/runs`, run status, SSE events, sessions) and on `API_SERVER_KEY`. Requires a reachability answer beyond loopback; the Mac being asleep is a first-class failure state, not an edge case.
- **Apple services added**: APNs (token-based auth with the team's `.p8` key, kept in `~/.iris`), ActivityKit and WidgetKit via a new `IrisWidgets` extension, and an App Group for the widget snapshot. Push is off unless a key is configured.
- **Iris Link grew** from pairing, tokens and a proxy into the phone's whole contract — tasks, steps, approvals, push and Live Activity registration, summary, voices, failure codes, new-chat recovery — documented in `ios/IrisLivePrototype/LINK_API.md`, which is the working contract between the two halves.
- **Third-party**: Gemini Live access from a mobile client (`@google/genai` has no Swift SDK — a WebSocket client or a relay is needed), Apple entitlements for background audio and notifications, and a Tailscale dependency for reaching the desktop's service.
- **Cost and risk**: an App Store/TestFlight distribution path, API keys on a mobile device, and an always-open microphone path are the main risks; each is addressed in design.md.
