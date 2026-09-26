## 1. Measure before deciding

- [ ] 1.1 Write `scripts/measure-live-latency.mjs`: connect with a given model and optional `thinkingConfig`, replay ten fixed pre-recorded spoken turns as 16 kHz PCM, log per turn end-of-speech → first audio byte, `usageMetadata`, and the output transcript — verify a run against the current 3.1 default produces ten timed rows (#5)
- [ ] 1.2 Run it for 3.1/minimal, `gemini-3.8-live`, `gemini-3.8-live-extended-thinking` at `low` and at `medium`; rate the transcripts blind; record median/p90 latency, tokens per turn and quality notes under *Measurements* in design.md — verify the table is filled and a recommendation is written
- [ ] 1.3 Confirm with a constrained ephemeral token that `gemini-3.8-live` rejects `thinkingLevel` and the extended-thinking model accepts `low`/`medium`/`high` and not `minimal` (extend `scripts/test-live-ephemeral-token.mjs` to send the mobile config) — verify the accepted and refused combinations are logged

## 2. One resolver

- [ ] 2.1 Add `liveModel()` and `liveThinking()` to the main process and replace the seven inline `models/gemini-3.1-flash-live-preview` fallbacks; default to `models/gemini-3.8-live`; add 3.8 and 3.8-extended-thinking to `GEMINI_LIVE_MODELS` and keep 3.1 selectable — verify `npm test` and that `/link/status` reports the new default with no env override (#6)
- [ ] 2.2 Feed the resolver into `buildLiveConfig` and `buildMobileLiveConfig`, never into `buildMobilePreviewConfig`; never send `thinkingLevel` to a model that rejects it — verify unit tests for each model × level combination produce the right config or none (#6)
- [ ] 2.3 Add `GEMINI_LIVE_THINKING` (`off` default; only the levels 1.2 justified) to the env allowlist, the Settings panel with the measured latency stated beside it, and README — verify changing it in Settings restarts the session on the new model and the handle is dropped as 3117bd5 requires

## 3. Re-verify what 3.1 taught us

- [ ] 3.1 Phone loudspeaker: hold a two-minute conversation on 3.8 on the speaker and confirm Iris does not cut herself off; re-tune `startOfSpeechSensitivity` if she does — record the outcome in design.md
- [ ] 3.2 Barge-in during a Hermes read-back on both apps: confirm the gate's invalidation rule still fires and a spoken yes after an interruption is refused
- [ ] 3.3 Let a phone session run 30 minutes on 3.8 and confirm the token-expiry 1011 close reconnects on a fresh token and resumes; let a desktop session sleep and wake and confirm it resumes
- [ ] 3.4 Voice preview and accent instruction on 3.8: confirm a preview token still speaks the exact sample line in the requested voice and accent

## 4. Sweep the name

- [ ] 4.1 Update the phone's fallbacks (`LiveClient.swift`, `ContentView.swift`, `VoicePreviewController.swift`), the probes, `linkHarness.mjs`, `LINK_API.md` examples, `README.md`, `ARCHITECTURE.md`, and the test fixtures — verify `grep -r "3.1-flash-live"` outside `openspec/` and git history returns only the "still selectable" mention
- [ ] 4.2 Flip the default and run the full desktop and iOS test suites — verify green, and that a machine with `GEMINI_LIVE_MODEL=models/gemini-3.1-flash-live-preview` still works unchanged
