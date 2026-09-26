## Context

See proposal.md — Why.

- The model name is a hard-coded fallback in seven places in `electron/main.mjs` (`:310, :531, :586, :1067, :2968, :3498, :4109, :4683`) and in the phone (`LiveClient.swift:208, :226`, `ContentView.swift:405, :1244`, `VoicePreviewController.swift:117`). The phone only uses its fallback when the minted token reports no model, which the desktop always does.
- `buildLiveConfig()` (`main.mjs:2815-2850`) sets no `thinkingConfig`. Per Google's Live guide, 3.1 defaults `thinkingLevel` to `minimal`; `gemini-3.8-live` must not be sent `thinkingLevel` at all; `gemini-3.8-live-extended-thinking` accepts `low` / `medium` / `high` (no `minimal`) and `includeThoughts`.
- Phone sessions and previews are defined entirely by the token's `liveConnectConstraints.config` (`mintGeminiToken`, `main.mjs:4100-4160`); the phone's own setup frame carries only the model.
- Resume handles are bound to the model (3117bd5): changing the model drops the handle and starts a fresh conversation, which is the behavior we want here.
- Behavior tuned by ear against 3.1: `START_SENSITIVITY_LOW` for the phone loudspeaker (`mobileSession.mjs:160-163`), the 48-audible-character barge-in rule in the desktop gate, and the 1011-close classification.

## Goals / Non-Goals

**Goals:**
- One place that knows the default model, and one that knows how thinking maps to a model + config.
- A recorded measurement, not an opinion, behind any thinking default.
- Nothing tuned on device silently regresses.

**Non-Goals:**
- Thinking on voice previews (one fixed sample line; nothing to think about).
- Changing the Hermes routing rule or the system prompt beyond what the model swap requires.
- Removing 3.1 from the selectable list while Google still serves it.

## Decisions

### 1. One resolver for the model, one for thinking

`liveModel()` replaces the seven inline fallbacks; `liveThinking()` reads `GEMINI_LIVE_THINKING` and returns `{ model, thinkingConfig }`: `off` → `gemini-3.8-live`, no `thinkingConfig`; any level → `gemini-3.8-live-extended-thinking` with `thinkingConfig: { thinkingLevel }`. If `GEMINI_LIVE_MODEL` is set explicitly it wins for the model, and thinking is applied only when that model supports it (3.1 accepts `minimal`–`high`; plain 3.8 rejects the field and the resolver must not send it). Both `buildLiveConfig` and `buildMobileLiveConfig` consume the same result, so the phone and the Mac think alike. `buildMobilePreviewConfig` never receives it.

Alternative: leave thinking as a raw `GEMINI_LIVE_THINKING_LEVEL` and a separately chosen model. Rejected: it lets a user pair `thinkingLevel` with a model that rejects it and get a failed connect at session start.

### 2. The experiment is a script, and it runs before the setting exists

`scripts/measure-live-latency.mjs`: connects with a given model and thinking config, sends a fixed list of ten spoken turns as pre-recorded 16 kHz PCM (so every run hears the same audio), and logs per turn the interval from `audioStreamEnd` to the first `inlineData` byte, plus the output transcript. Runs: 3.1/minimal, 3.8/none, 3.8-ext/low, 3.8-ext/medium. The turns mix trivially conversational ("what's a good name for a grey cat"), reasoning-shaped ("if I leave at 4:10 and the drive is 35 minutes, when do I arrive, and is that before 5"), and a follow-up that needs the earlier turn. Quality is rated blind from the transcripts. Results go in this file under *Measurements*. The setting in decision 1 is only built with the levels the numbers justify.

Alternative: judge by ear in a real session. Rejected: turn-to-turn variance is larger than the effect we're looking for; a fixed script is the only way to compare.

### 3. Recorded re-verification, not assumed carry-over

Each item tuned on 3.1 is re-run on 3.8 with its original evidence: the constrained-token acceptance check (`scripts/test-live-ephemeral-token.mjs` extended to send the mobile config), the loudspeaker self-interruption on a phone, a barge-in during read-back, a 30-minute session to see the 1011 expiry close, and a resume across a reconnect. Any difference is fixed or recorded here before the default flips.

## Risks / Trade-offs

- [3.8 turn-taking differs from 3.1 and the loudspeaker cut-off returns] → re-verification on device before the default changes; `START_SENSITIVITY_LOW` is re-tuned if needed.
- [Thinking adds a beat before every answer] → measured first; default stays `off` unless `low` is within a bound the user accepts after hearing it. Recorded here.
- [Google withdraws 3.1 before this lands] → the env override already lets any user move today; the change just makes it the default.
- [Thinking tokens raise output cost] → billed as text output; the script logs `usageMetadata` per turn so the number is known.

## Migration Plan

Flip the default in code; `~/.iris/.env` needs no edit unless the user pinned 3.1 explicitly, in which case README says to remove or update the line. First session after the change starts fresh (handle bound to the old model). Rollback: `GEMINI_LIVE_MODEL=models/gemini-3.1-flash-live-preview`.

## Measurements

_To be filled by task 1.2: median and p90 end-of-speech → first-audio per configuration, output tokens per turn, and blind quality notes._
