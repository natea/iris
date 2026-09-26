## Why

An iOS conversation never ends by itself. Once the orb is tapped, every microphone chunk — speech or silence — streams to Gemini Live ungated (`ios/IrisLivePrototype/Sources/ContentView.swift:890-909`), the session reconnects itself on a fresh token before every server deadline (`ReconnectPolicy.swift`), and the `audio` background mode keeps it alive with the phone locked in a pocket. A forgotten session bills audio-input tokens indefinitely, until the user opens the app and taps the orb again. The Mac already pays only while awake: a local wake word, a 30 s idle standby that closes the socket, and a headless handle refresh that keeps the conversation resumable (`electron/main.mjs:206-208, 3560-3600, 3456-3460`). The phone has none of the three.

## What Changes

- **Idle standby on the phone.** A session that has been quiet for a configurable interval ends itself: socket closed, microphone released, lock-screen presence gone. "Quiet" follows the Mac's rules (`electron/liveSessionState.mjs` `autoSleepDecision`): the clock is reset by recognized user speech, by Iris speaking, and by local speech onsets; the limit is extended while a proposal is waiting for an answer; standby never fires mid-response or while a completion announcement is queued or in flight.
- **Resume after standby.** The session's last resumption handle survives standby. A wake inside Google's handle window resumes the same conversation on a freshly minted token, exactly as a reconnect does today; a wake after it starts a fresh conversation and Iris says so (the existing "started a fresh conversation" line). The phone cannot rotate handles while suspended, so unlike the Mac the window is a hard ~2 h ceiling and the spec says so.
- **Siri as the hands-free wake.** `StartIrisSessionIntent` and `SendTaskToIrisIntent`, exposed through an `AppShortcutsProvider` so "Hey Siri, start Iris" works with no user setup. Starting capture needs the foreground on iOS, so the start intent opens the app; the task intent needs no microphone and stages the brief for the next session. Design decision 7 of `add-ios-voice-companion` already commits to Siri as an ignition key, not a voice channel; this change builds it, and its first task is the throwaway prototype that decides whether the two-beat wake (Siri, then Iris) feels acceptable and whether question-shaped phrases survive Siri.
- **Asleep is a visible state.** The orb, the status line, the Now Playing entry and the Live Activity distinguish "asleep, tap or ask Siri to wake" from "stopped", and the Hermes completion that would have been spoken is delivered as a push exactly as it is for a stopped session today.
- **Tasks move, not duplicate.** Tasks 1.4, 1.5, 4.9, 6.1 and 6.2 of `add-ios-voice-companion` are the iOS side of this work and move here; 6.3 and 6.4 (macOS URL scheme and helper app) stay where they are.
- Not in scope: gating microphone audio on local VAD while a session is awake (a separate change, since it changes how Gemini's server-side turn detection sees the stream), and any Mac-side behavior.

## Capabilities

### New Capabilities
- None.

### Modified Capabilities
- `mobile/ios-voice-companion`: the "Idle session ends itself" scenario under *User-initiated voice sessions* becomes a full requirement with the standby rules, and new requirements are added for resuming after standby, for the sleeping state being visible and wakeable, and for Siri as an entry point. The base spec is not yet in `openspec/specs/` — it lives in the unarchived `add-ios-voice-companion` change — so this delta is written against that file and must be applied after it is synced.

## Impact

- **iOS app** (`ios/IrisLivePrototype`): `LiveSessionController` (`ContentView.swift`) gains a standby timer and a sleeping state distinct from stopped; `SessionCoordinator` exposes the activity edges the timer needs (it already tracks `modelTurnActive`, the user transcript buffer and in-flight announcements for `isMidTurn()`); `BackgroundSession` learns a "sleeping" Now Playing state; `LiveActivityController` and `IrisWidgets` show it; a new App Intents file and an entry in `Info.plist`. Settings gains the standby interval.
- **Desktop / Iris Link**: none. Resume already travels through `POST /link/gemini-token` `resume_handle`; the token minter and `LINK_API.md` are unchanged.
- **Cost**: audio-input tokens are billed only while a session is awake, plus one idle tail per exchange — the Mac's model.
- **Risk**: Siri's behavior with question-shaped phrases and the felt latency of an intent-driven launch are forum-sourced claims, not measured; the first task measures them before any UI is built.
