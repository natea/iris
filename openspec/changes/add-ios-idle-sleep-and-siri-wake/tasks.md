## 1. Prototypes that decide the Siri half

- [ ] 1.1 Throwaway `StartIrisSessionIntent` with `openAppWhenRun = true` in a scratch target: time "Hey Siri" → microphone live on a locked iPhone across ten tries — verify the median is recorded in design.md and the launch is judged as assistant-like or app-launch-like (moved from add-ios-voice-companion 1.4)
- [ ] 1.2 Throwaway question-shaped phrase ("ask Iris to research X") and imperative phrase ("send X to Iris"): verify which strings reach the intent unchanged and which Siri answers itself; record the outcome and settle the published phrase list before any UI (moved from add-ios-voice-companion 1.5)

## 2. Standby policy

- [ ] 2.1 Add `StandbyPolicy` as a Swift value type mirroring `autoSleepDecision` in `electron/liveSessionState.mjs` (idle limit, ×3 with a pending proposal, response protection with `max(120 s, 4×idle)`, local-speech veto) — verify unit tests ported from the desktop's cases pass on the same inputs and outputs (#1)
- [ ] 2.2 Track turn timing in `SessionCoordinator`: a `turnStartedAt` alongside what `isMidTurn()` already reads, and a `lastActivityAt` bumped by input transcript, output transcript, interruption, sent text, a tapped answer and an announcement starting — verify with a test that silence after a completed model turn advances idle time and a new user transcript resets it (#2)
- [ ] 2.3 Expose a "local speech likely" signal from `AudioEngine`'s existing input level (above the noise floor for the last two ticks) — verify it is false on a silent room and true while someone is speaking, and that it never opens or sends anything (#3)

## 3. Sleep, wake and resume

- [ ] 3.1 Add an `asleep` phase to `LiveSessionController`: `sleep()` closes the socket, coordinator and audio engine and clears Now Playing exactly as `stop()` does, but keeps `resumeHandle`, the session voice and a sleep timestamp; `stop()` still clears everything — verify a unit test that `sleep()` then `start()` mints with the handle and `stop()` then `start()` does not (#4)
- [ ] 3.2 Run the policy on a 5 s tick while running and call `sleep()` on a sleep decision; never while a completion announcement is queued or in flight — verify on device that a session left alone after an exchange sleeps at the configured interval and that a session with a pending proposal sleeps at three times it (#4)
- [ ] 3.3 Drop the handle on wake when it is older than the resumption window, so the existing fresh-conversation message fires — verify a wake at 1 h resumes (Iris does not re-greet) and a wake at 2 h 05 starts fresh and says so
- [ ] 3.4 Add the standby interval to Settings next to voice and handedness: default 30 s, floor 15 s, 0 disables with a one-line statement of the cost — verify the value persists and the tick reads the new value on the next idle period

## 4. Asleep is visible

- [ ] 4.1 Orb and status line show "Asleep — tap to wake" and the tap wakes; the transcript stays on screen — verify with a UI test on the fixture that the asleep state renders and the control's label reads as a wake
- [ ] 4.2 Now Playing is cleared on sleep so the lock screen shows no live microphone; verify on device that Control Center offers nothing to stop while asleep and that the process is allowed to suspend
- [ ] 4.3 Where a run card or the Live Activity says the assistant is listening, read "asleep" instead while in standby, as a local overlay with no change to the desktop's pushed state — verify with a snapshot test
- [ ] 4.4 Completion while asleep: verify on device that a run finishing during standby arrives as a push, and that the next wake speaks it only if it was not acknowledged

## 5. Siri entry points

- [ ] 5.1 Ship `StartIrisSessionIntent` (`openAppWhenRun`) and `SendTaskToIrisIntent` (`String` parameter, `requestValue` when omitted, background) with an `AppShortcutsProvider` whose phrases carry `\(.applicationName)` and follow 1.2's outcome — verify both appear in the Shortcuts app with no setup (moved from add-ios-voice-companion 6.1)
- [ ] 5.2 Route the task intent's text through the same path a typed message takes so it is staged as a proposal and never dispatched by the intent — verify a unit test that the intent produces a pending proposal and no dispatch, and on device that the spoken string reaches the app unchanged (moved from add-ios-voice-companion 6.2)
- [ ] 5.3 Wake-by-Siri resumes under the rules in 3.3 — verify on device that "Hey Siri, start Iris" within the window continues the conversation

## 6. Documentation and bookkeeping

- [ ] 6.1 Remove tasks 1.4, 1.5, 4.9, 6.1 and 6.2 from `add-ios-voice-companion/tasks.md` with a pointer to this change; leave 6.3 and 6.4 — verify `openspec validate` passes on both changes
- [ ] 6.2 Add standby, the resume window and the Siri phrases to the setup guide (add-ios-voice-companion 8.2 or `LINK_API.md`'s companion notes) — verify the guide states the 2 h window and the phrases that work
- [ ] 6.3 Confirm the cost model end to end: a session left alone after one exchange, measured in Google AI Studio's usage for the key, shows audio-input tokens stop within the standby interval — verify the number is recorded in design.md
