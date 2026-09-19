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
- **Third-party**: Gemini Live access from a mobile client (`@google/genai` has no Swift SDK — a WebSocket client or a relay is needed), Apple entitlements for background audio and notifications, and a Tailscale dependency for reaching the desktop's service.
- **Cost and risk**: an App Store/TestFlight distribution path, API keys on a mobile device, and an always-open microphone path are the main risks; each is addressed in design.md.
