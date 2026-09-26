## Why

`models/gemini-3.1-flash-live-preview` is now marked legacy by Google ("We recommend updating to Gemini 3.8 Live"), and Iris pins it as a default in seven places in `electron/main.mjs` plus the phone's fallbacks and every probe. The replacement costs the same (one shared price table: $3.00/M audio in, $12.00/M audio out, $0.005 and $0.018 per minute), so this is a longevity move — and the natural moment to answer a question we have never measured: whether a little thinking makes Iris noticeably smarter on the questions she already answers herself, and what it costs in time-to-first-audio.

## What Changes

- **Default model becomes `models/gemini-3.8-live`** everywhere the old name is a fallback: `GEMINI_LIVE_MODELS`, the desktop session, the desktop preview, the standby handle refresh, the phone token minter, `/link/status`, the phone's own fallbacks, the probes, README and `LINK_API.md` examples. `GEMINI_LIVE_MODEL` in `~/.iris/.env` still overrides, and 3.1 stays selectable while Google keeps it.
- **A measured thinking experiment, before any default changes.** `thinkingLevel` is set nowhere today, so Iris runs at 3.1's `minimal`. The experiment runs the same fixed script of spoken turns against: 3.1 at `minimal` (today's baseline), `gemini-3.8-live` (no thinking; the model rejects `thinkingLevel`), and `gemini-3.8-live-extended-thinking` at `low` and `medium`. Measured: time from end of user speech to first audio byte, and a blind quality rating of the answers. The outcome is recorded in design.md and decides whether thinking is offered at all.
- **`GEMINI_LIVE_THINKING` setting** (`off` | `low` | `medium` | `high`), only if the experiment finds a level whose latency is acceptable. It selects the extended-thinking model and sets `thinkingLevel`; `off` keeps the plain 3.8 model. Exposed in desktop Settings with the measured latency stated next to it. Applies to the desktop session and to phone session tokens; never to voice previews.
- **Re-verify what was tuned against 3.1 on the new model**, on device: the loudspeaker self-interruption fix (`START_SENSITIVITY_LOW`, 18d96f5), barge-in and read-back invalidation, resume-handle rotation and the 1011 close semantics (759a0a5), ephemeral token acceptance of the constrained config, and the accent instruction.
- Not in scope: any change to what Iris routes to Hermes. Hermes is where tools and long work live; a smarter Live turn does not replace it.

## Capabilities

### New Capabilities
- None.

### Modified Capabilities
- None. The model and thinking level are configuration; no requirement in `agent-dispatch-contract`, `mobile/ios-voice-companion` or `mobile/client-pairing` names a model or a latency figure. `skip_specs: true`.

## Impact

- **Code**: `electron/main.mjs` (model defaults, `buildLiveConfig`, `mintGeminiToken`, `GEMINI_LIVE_MODELS`, settings plumbing), `electron/mobileSession.mjs` (thinking in the phone config), `src` Settings panel, `scripts/test-live-ephemeral-token.mjs`, `test/irisLinkServer.test.mjs` fixtures, iOS fallbacks in `LiveClient.swift`, `ContentView.swift`, `VoicePreviewController.swift`, the probe tools and `LINK_API.md`.
- **Config**: `~/.iris/.env` — `GEMINI_LIVE_MODEL` (currently `models/gemini-3.1-flash-live-preview`) and the new `GEMINI_LIVE_THINKING`.
- **Cost**: unchanged per token. Thinking tokens bill as text output ($4.50/M); for short spoken turns this is small, and the experiment records it.
- **Risk**: a model swap can change turn-taking behavior that was tuned by ear on a phone; the re-verification tasks exist for that reason, and 3.1 remains one env line away.
