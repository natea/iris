## Context

See proposal.md — Why. What the code does today, as read:

- `LiveSessionController` (`ContentView.swift`) has two states, `isRunning` true or false. `stop()` (`:598`) tears down everything including `resumeHandle` (`:614`). There is no third state.
- The session loop mints a token with `resumeHandle` on every (re)connect (`:352`) and keeps the latest handle from `sessionResumptionUpdate` (`:722-726`). Resume already works across reconnects; what is missing is a stop that keeps the handle.
- `SessionCoordinator.isMidTurn()` (`:407-411`) already knows when the model is speaking, an announcement is in flight, or the user transcript buffer is non-empty. The reconnect path uses it to avoid cutting a turn. Standby needs the same inputs plus a timestamp.
- The iOS build has no local VAD. The phone's only speech signals are Gemini's own: `inputTranscript`, `outputTranscript`, `interrupted`. The Mac additionally has Silero, which is why its idle clock also resets on local speech onsets.
- `BackgroundSession` (`BackgroundSession.swift`) publishes a Now Playing entry with a stop target while running, and clears it on stop. The `audio` background mode keeps the process alive only while `.playAndRecord` is active.
- The desktop's decision logic is `autoSleepDecision()` in `electron/liveSessionState.mjs`: idle limit, ×3 while a proposal is pending, response-in-flight protection with a `max(120 s, 4×idle)` ceiling, and never while local speech is active. Default 30 s, floor 15 s, 0 disables.
- Google expires a resumption handle 2 h after disconnect. The Mac reconnects headlessly at 110 min to rotate it. A suspended iOS app cannot.
- Two URL schemes exist (`iris-link://` pairing, `iris://run/<id>`); there is no App Intents code anywhere in the target.

## Goals / Non-Goals

**Goals:**
- Same cost model as the Mac: tokens only while awake, one idle tail per exchange.
- One decision function shared with the Mac's rules, tested with the desktop's cases ported, as `DispatchGate` was.
- Standby is a distinct state the user can see, not a synonym for stopped.
- Siri is buildable only after the prototype says the launch is acceptable; the standby half does not depend on Siri.

**Non-Goals:**
- Extending the resume window from the phone (background reconnects are not reliable and would reopen a billed connection).
- A wake word on the phone: no third-party always-on microphone exists on iOS.
- Gating microphone audio on local VAD while awake. Separate change; it alters what Gemini's server VAD sees.
- Any desktop or Iris Link change.

## Decisions

### 1. A third session state, `asleep`, that keeps the handle and nothing else

`stop()` becomes two paths. `sleep()` cancels the loop, closes the socket and coordinator, stops the audio engine and clears Now Playing exactly as `stop()` does — but keeps `resumeHandle`, the `sessionVoice` and the sleep timestamp, and sets `phase = .asleep`. `stop()` (the user's explicit stop) clears them. `start()` reads the handle if present and it is younger than the window; otherwise drops it. The session loop's existing "resumed == false with a handle" path (`:397-399`) already produces the fresh-conversation message, so no new messaging code.

Alternative: keep the socket open and just mute. Rejected — a muted stream still bills zeros (this is the whole problem).

Alternative: background-reconnect at 110 min like the Mac. Rejected — iOS suspends the app, background execution is not guaranteed, and a reconnect that does run reopens a billed connection with nobody talking.

### 2. Standby decision ported, not reinvented

A Swift `StandbyPolicy` value type with `decide(now:idleMs:lastActivityAt:pendingProposal:responseInFlight:responseStartedAt:)` mirroring `autoSleepDecision`, and its unit tests are the desktop's cases translated, so the two apps sleep under the same rules. The controller runs it on a 5 s tick while `phase == .running`, as the Mac does.

Inputs on the phone:
- `lastActivityAt` bumps on: `inputTranscript` (recognized speech, as the Mac's `:3280`), `outputTranscript` / model audio (Iris speaking, `:3332`), `interrupted`, text sent by the user, a tapped answer, and a queued announcement starting.
- `responseInFlight` / `responseStartedAt`: from the coordinator, extended from what `isMidTurn()` already tracks — it gains a `turnStartedAt`.
- `pendingProposal`: the published `pendingProposal` the answer buttons already read.

What the phone lacks: a local speech-onset signal. Gemini's `inputTranscript` arrives a second or two after the user starts talking, so a user who starts speaking at second 29 of a 30 s window could be cut off. Mitigation: the tick reads the audio engine's input level (it already computes one for the orb) and treats a level above the noise floor for the last two ticks as "local speech active", the same veto the Mac gets from Silero. Not a VAD, just enough to not hang up on someone mid-word.

### 3. Defaults and setting

Default 30 s, floor 15 s, 0 disables, in `UserDefaults` next to voice and handedness — the Mac's numbers, so the two feel the same. The Settings row states the trade-off in one line ("Iris keeps listening — and billing — until you stop her") when disabled.

### 4. Asleep on screen, on the lock screen, in the activity

- Orb: a dimmed state with "Asleep — tap to wake" as the status line. Tapping wakes; the same control that used to say "Tap to talk".
- Now Playing: cleared on sleep (there is no microphone to be honest about), so the lock screen shows no live-stream entry. The alternative — a "sleeping" Now Playing entry — would keep an audio-session claim and could keep the process alive for nothing.
- Live Activity: the activity is about Hermes runs, not the session, and stays as it is. The one change is the "listening" affordance, if any run card shows it, reads "asleep". The desktop's pushed `ContentState` is unchanged; the sleeping/awake distinction is a local overlay.
- Completions while asleep: already handled — a run finishing with no live session is pushed by the desktop (`pushNotifier`), and the "unannounced completions" fetch at session start speaks it on wake if the phone has not acknowledged it. No new path.

### 5. Siri: two intents, one throwaway first

`StartIrisSessionIntent` with `openAppWhenRun = true` — iOS will not start capture from the background, full stop. `SendTaskToIrisIntent` with a `String` parameter, `requestValue` when omitted, runs in the background, and hands the text to the app through the same path a typed message takes, so it becomes a *proposal* the user still confirms. Both are published by an `AppShortcutsProvider` with phrases containing `\(.applicationName)`.

The first task is a throwaway build that measures two things before any UI: "Hey Siri, start Iris" to microphone-live in seconds, felt on a locked phone; and whether "ask Iris to research X" is passed through or answered by Siri. If the launch feels like an app launch rather than an assistant, the start intent is still shipped (it is the only hands-free path) but the setup guide says what to expect. If question-shaped phrases are intercepted, the published phrases are imperative only.

Alternative: a Shortcut the user builds. Rejected as the primary path — App Shortcuts need no setup and give branded phrases — but it works today and is what the guide suggests until this ships.

## Risks / Trade-offs

- [Cut off mid-sentence at the window edge] → level-based veto in decision 2; default 30 s matches the Mac where this has not been a reported problem.
- [Resume window is a hard 2 h on the phone] → stated in the spec and the setup guide; the fresh-conversation message already exists and is honest.
- [Siri launch feels slow] → measured first (task 1.1); shipped regardless as the only hands-free option, with expectations set in the guide.
- [Siri answers question-shaped phrases itself] → measured first (task 1.2); phrases are imperative if so.
- [`audio` background mode and Now Playing cleared on sleep means the app may be suspended] → intended: a suspended app costs nothing; wake is a launch anyway.
- [A pending proposal survives standby but the model's context does not if the window passes] → the proposal is still on screen and a tap still dispatches the brief that is on screen (the button path does not need the model); a voice yes to a fresh conversation would not know what "yes" refers to, which the fresh-conversation line covers.

## Migration Plan

No data migration. The standby setting defaults on. The base `mobile/ios-voice-companion` spec must be synced from `add-ios-voice-companion` before this change's delta is archived. Rollback is the setting set to 0.

## Open Questions

- Whether `MPNowPlayingInfoCenter` needs a sleeping entry for the Control Center "recently played" tile to offer a wake. Deferrable: it changes a nicety, not the spec.
