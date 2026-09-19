# Iris Link API — the contract the phone implements

This document is the complete contract between the Iris desktop app (macOS,
Electron) and a paired phone. It is written so the phone can be built without
reading the desktop's source: every route, every error code, every tool the
model will call, the exact JSON the phone must return for each one, the exact
text of the system events it must inject, the dispatch gate it must enforce,
and the announced/undelivered protocol.

Desktop sources of truth, for anyone who does want to read them:
`electron/irisLinkServer.mjs` (routes), `electron/mobileSession.mjs` (the
config baked into the token), `electron/hermesTools.mjs` (tool schemas),
`electron/hermesGate.mjs` (the gate), `electron/main.mjs` (`mintGeminiToken`,
`submitHermesTask`, `executeTool`), `electron/hermesEvents.mjs` (the
completion event text).

---

## 1. Transport and authentication

Iris Link runs inside the desktop app, bound **only** to the Mac's Tailscale
address. It is off unless `IRIS_LINK_ENABLED=1`. Default port `8765`.

- **Base URL**: `http://<tailscale-host>:<port>` (the prototype; production
  will serve HTTPS on the MagicDNS `*.ts.net` name — see design.md).
- **Auth**: `Authorization: Bearer <device credential>` on every request
  except `POST /link/pair`.
- **Bodies**: JSON only. A `Content-Type` other than `application/json` on a
  POST is refused with **415 `unsupported_media_type`**. Bodies over **64 KiB**
  are refused with **413 `payload_too_large`**.
- **Responses**: always JSON, always `Cache-Control: no-store`,
  `X-Content-Type-Options: nosniff`. There is no CORS. Errors are always
  `{"error": "<code>"}`, sometimes with a `"message"` string (never a
  credential, key, or token).
- **Timeouts**: headers 20 s, request 60 s, keep-alive 15 s. A proxied Hermes
  call is aborted after 30 s (SSE streams are exempt).

### Failures that apply to every authenticated route

| Status | Body | Meaning |
| --- | --- | --- |
| 401 | `{"error":"not_paired"}` | Missing, malformed, or revoked bearer credential. The phone should re-pair; never retry silently in a loop. |
| 404 | `{"error":"not_found"}` | Unknown path. |
| 405 | `{"error":"method_not_allowed"}` | Right path, wrong method. |
| 413 | `{"error":"payload_too_large"}` | Body over 64 KiB. |
| 415 | `{"error":"unsupported_media_type"}` | Non-JSON `Content-Type`. |
| 500 | `{"error":"internal_error"}` | Unexpected desktop-side failure. |
| 501 | `{"error":"tasks_unavailable"}` | The desktop did not wire the task API (older build). Treat as "dispatch is unavailable from the phone", and say so. |

---

## 2. Pairing

### `POST /link/pair` — unauthenticated

Request: `{"secret": "<from the QR payload>", "deviceName": "Nate's iPhone"}`

`200` → `{"deviceId": "...", "credential": "...", "code": "123456"}`

The credential is returned **exactly once**. Store it in the Keychain with
`WhenUnlockedThisDeviceOnly`. `code` is the six digits also shown on the Mac;
show it so the user can compare.

Errors: `400 offer_unknown` · `400 offer_used` · `400 offer_expired` ·
`429 too_many_attempts` (the offer is burned; the user must create a new one) ·
`429 rate_limited` (more than 10 pairing attempts per minute from one address) ·
`400 invalid_json`.

---

## 3. Status and token

### `GET /link/status`

```json
{
  "ok": true,
  "deviceId": "…",
  "deviceName": "Nate's iPhone",
  "hermesReachable": true,
  "userName": "Nate",
  "liveModel": "models/gemini-3.1-flash-live-preview",
  "voice": "Zephyr",
  "accent": ""
}
```

`hermesReachable` is a **live** probe of Hermes, time-bounded to 2.5 s and
cached for 5 s. If the probe times out the previous answer is returned rather
than a guess. Poll this no more often than every few seconds.

The phone must distinguish two different outages and say which one it is:
the request failing at all = the **Mac/Link** is unreachable;
`hermesReachable: false` = the Mac is up but **Hermes** is not.

### `POST /link/gemini-token`

Body: none. `200` →

```json
{
  "token": "auth_tokens/…",
  "expiresAt": "ISO-8601",
  "newSessionExpiresAt": "ISO-8601",
  "model": "models/gemini-3.1-flash-live-preview"
}
```

`502 token_unavailable` if the mint failed (no key configured, upstream error).

- The token must be used to **start** a session before `newSessionExpiresAt`
  (60 s) and the session may run until `expiresAt` (30 min). `uses: 1`.
- Connect with **`v1alpha`** and pass the token as the API key.
- **Send an empty setup config.** The token carries
  `liveConnectConstraints.config`, which *replaces* whatever the client sends:
  voice, transcription, system instruction and tool declarations all come from
  the Mac. Anything the phone puts in its setup frame is silently ignored.
- An early WebSocket close with code **1011** is an authorization failure
  (expired/spent token), not a network blip. Mint a new token; do not retry the
  same one.

### What the token's config contains (informational — do not send it)

Verified accepted by the real token endpoint on 2026-09-19:

```jsonc
{
  "responseModalities": ["AUDIO"],
  "speechConfig": { "voiceConfig": { "prebuiltVoiceConfig": { "voiceName": "Zephyr" } } },
  "sessionResumption": {},          // accepted
  "inputAudioTranscription": {},    // accepted
  "outputAudioTranscription": {},   // accepted
  "tools": [ { "googleSearch": {} }, { "functionDeclarations": [ … §5 … ] } ],
  "systemInstruction": { "parts": [ { "text": "…" }, { "text": "USER CONTEXT …" } ] }
}
```

Because `sessionResumption: {}` is enabled, the server will send
`sessionResumptionUpdate` messages: keep the newest `newHandle` and reconnect
with it to continue the same conversation. Because both transcription fields
are set, the phone receives `inputTranscription` / `outputTranscription` — the
input transcript is what the gate uses to observe the user's turn (§6).

---

## 4. The task API

All of these require the bearer credential. `:id` is a Hermes run id (a single
path segment, ≤ 200 characters, no slashes or control characters).

### `POST /link/tasks` — dispatch

Request: `{"task": "<the complete brief>", "urgency": "low"|"normal"|"high"}`
(`urgency` optional, defaults to `"normal"`).

`200` →

```json
{
  "status": "started",
  "run_id": "…",
  "message": "Hermes has started the task.",
  "origin": "device:<deviceId>"
}
```

This goes through the desktop's own dispatch path: the same pinned Hermes
session, the same safety instructions, the same memory key, the same run
registry, and a task card on the Mac.

**The desktop's confirmation gate is not applied here and is not consumed by
this call.** Link dispatch is trusted to have been gated on the phone. The
phone MUST run the gate in §6 before ever calling this route.

Errors: `400 task_required` (missing/blank) · `400 task_too_long` (> 20 000
characters) · `400 invalid_urgency` · `400 invalid_json` ·
`502 agent_unreachable` (the desktop could not reach Hermes) ·
`502 dispatch_failed` (Hermes refused or returned no run id; `message` carries
the reason) · `501 tasks_unavailable`.

### `GET /link/tasks` — list

`GET /link/tasks` → `{"tasks": [ … ]}`, most recently updated first (by
`updated_at`), up to 50 entries, for the pinned Hermes session — **including runs dispatched from the desktop**.

```json
{
  "run_id": "…",
  "task": "…",
  "status": "started|running|completed|failed|cancelled|…",
  "origin": "desktop" | "device:<deviceId>",
  "created_at": 1758240000000,
  "updated_at": 1758240300000,
  "announced_at": 0
}
```

`created_at` / `updated_at` / `announced_at` are epoch milliseconds.
Terminal statuses are `completed`, `failed`, `cancelled`, `canceled`, `error`.

`GET /link/tasks?undelivered=1` → the same shape, filtered to runs that are
**terminal**, dispatched by **this device**, and **not yet acknowledged**. See
§8.

### `GET /link/tasks/:id` — honest status

`200` → the list entry above, merged with the live status from the same path
the desktop uses:

```json
{
  "run_id": "…", "task": "…", "origin": "…",
  "status": "running",
  "instructions": "The run is STILL IN PROGRESS. …"
}
```

When the run is terminal the body also carries `"output": "…"`. When the
desktop could not fetch the status it returns `"status": "error"` with an
`"error"` string — report that verbatim, never a guessed status.

`404 task_unknown` for an id the desktop has never seen.

### `GET /link/tasks/:id/result` — the stored result

`200` →

```json
{
  "ok": true,
  "run_id": "…",
  "task": "…",
  "status": "completed",
  "output": "the complete stored Hermes output",
  "instructions": "Answer only from this complete Hermes result."
}
```

Errors: `404 task_unknown` · **`409 task_not_finished`** (the run has not
reached a terminal status) · `404 result_unavailable` (terminal but the stored
result could not be restored — say it is unavailable, never invent it).

### `POST /link/tasks/:id/stop`

Body: none. `200` → `{"status": "stopping", "run_id": "…"}`.
Errors: `404 task_unknown` · `502 agent_unreachable`.

### `POST /link/tasks/:id/approval`

Body: `{"decision": "once"|"session"|"always"|"deny"}`.
`200` → `{"status": "resolved", "run_id": "…", "decision": "once"}`.

Errors: `400 invalid_decision` · `400 invalid_json` · `404 task_unknown` ·
**`409 approval_not_pending`** (Hermes has no pending approval for that run —
the desktop or a timeout already resolved it; tell the user plainly) ·
`502 agent_unreachable`.

> This route resolves the approval directly, exactly as the desktop's own
> approval buttons do. **The phone is therefore responsible for the human
> gate**: Iris must describe the command and reason, ask once / for this
> session / always / deny, END ITS TURN, and only call this after the user has
> answered in a turn of their own. Never call it from the same turn that
> presented the question.

> Hermes' *other* interactive prompts — clarification questions, sudo
> passwords, secrets — travel over Hermes' interactive WebSocket, which Iris
> Link does not carry. There is no route for them and the phone does not
> declare `respond_hermes_interaction`. When a run needs one, say it needs
> attention on the Mac.

### `POST /link/tasks/:id/announced`

Body: none. `200` → `{"ok": true, "run_id": "…"}`. `404 task_unknown`. See §8.

### `/hermes/*` — the raw allowlisted proxy

Still available, unchanged, for anything the task API does not cover (e.g. the
SSE activity stream). The desktop attaches Hermes' shared key; the phone never
sees it. Allowlist (method + path, `:id` = one segment):

`GET /v1/capabilities` · `POST /v1/runs` · `GET /v1/runs/:id` ·
`GET /v1/runs/:id/events` · `POST /v1/runs/:id/stop` ·
`POST /v1/runs/:id/approval` · `GET /api/sessions` · `POST /api/sessions` ·
`GET /api/sessions/:id/messages`.

Anything else → `403 route_not_allowed`. Upstream failure →
`502 agent_unreachable`.

**Prefer the `/link/tasks` routes for dispatch and status.** A run created
directly through `POST /hermes/v1/runs` bypasses the desktop's pinned session,
its safety instructions and the run registry: it will have no origin, no task
card, and the desktop may announce it aloud.

---

## 5. Tools the token declares

The model is given `googleSearch` plus exactly these eight function
declarations, in this order. Google Search is handled by the server; the phone
never sees a tool call for it.

Every tool result is returned as the function response `response` object. The
`instructions` strings below are load-bearing — the model's behavior depends on
them, and they are the desktop's own wording. **Return them verbatim.**

### 5.1 `check_hermes_status`

Args: none (`{}`).

Call `GET /link/status`. Return:

```json
{ "reachable": true, "health": { "transport": "iris_link" } }
```

or, when `hermesReachable` is false or `/link/status` itself failed:

```json
{ "reachable": false, "error": "Hermes is not reachable from the Mac." }
```

(Use an error string that names which of the two is down.)

### 5.2 `propose_hermes_task` — STEP 1, handled entirely on the phone

Args (`goal` required):

| Field | Type | Notes |
| --- | --- | --- |
| `goal` | string | What the user wants Hermes to accomplish. |
| `context` | string | Only context the user supplied or that was established in the conversation. |
| `constraints` | string[] | User-supplied limits, deadlines, budgets, exclusions, safety requirements. |
| `acceptance_criteria` | string[] | Observable conditions that make the work complete. |
| `output_format` | string | Requested result format, if any. |
| `urgency` | string enum | `low` \| `normal` \| `high`. |

Build the brief with **exactly** this format (the desktop's
`formatHermesBrief`) — sections joined by a blank line, omitted when empty, and
list items prefixed with `- `:

```
Goal:
<goal>

User-provided context:
<context>

Constraints:
- <constraint>

Acceptance criteria:
- <criterion>

Expected output:
<output_format>
```

Stage it in the gate (§6) and return:

```json
{
  "status": "proposed",
  "proposal_id": "<uuid>",
  "task": "<the formatted brief>",
  "instructions": "Now read this exact brief back to <UserName> in one or two short sentences, ask \"Should I send this to Hermes?\", and END YOUR TURN. Do NOT call submit_hermes_task yet — it will be rejected until they answer. Interpret <UserName>'s next response by meaning, not by matching specific words. If they clearly authorize sending, submit proposal_id \"<uuid>\". If they decline, call discard_hermes_proposal with that proposal_id. If they change any detail, call propose_hermes_task again and read back the replacement proposal. If their intent is ambiguous, ask one short natural clarification."
}
```

(The three sentences above are joined with single spaces, exactly as shown.)

If the brief is empty after formatting:

```json
{ "status": "error", "error": "A complete task brief is required." }
```

### 5.3 `submit_hermes_task` — STEP 2

Args: `{ "proposal_id": "<string>" }` (required).

1. Run the gate claim (§6).
2. **Rejected** → return, with `error` chosen from the table in §6.4:

```json
{
  "status": "blocked",
  "error": "REJECTED: …",
  "active_proposal_id": "<id or null>",
  "instructions": "…"
}
```

3. **Claimed** → `POST /link/tasks` with the claimed proposal's `task` and
   `urgency`, then return:

```json
{
  "status": "started",
  "run_id": "…",
  "origin": "device:…",
  "message": "Hermes has started the task.",
  "instructions": "Say ONE short acknowledgement (e.g. 'On it — Hermes is handling that now.'). The task has only STARTED: you have NO result yet. Do not describe, predict, or summarize any outcome until SYSTEM_EVENT_HERMES_COMPLETE arrives or get_hermes_task_status returns a terminal status."
}
```

4. If the dispatch call itself fails, return the failure honestly — do not
   claim it was sent:

```json
{
  "status": "error",
  "error": "<agent_unreachable | dispatch_failed | …>",
  "instructions": "Say the task could not be sent and why. Do not claim Hermes is working on it."
}
```

   A claimed proposal is consumed. After a failed dispatch the model must stage
   a fresh proposal rather than retrying the same `proposal_id`.

### 5.4 `discard_hermes_proposal`

Args: `{ "proposal_id": "<string>" }` (required).

Success:

```json
{
  "status": "discarded",
  "proposal_id": "…",
  "instructions": "Acknowledge the decline briefly. Do not send this proposal to Hermes."
}
```

Failure (`no_proposal`, `proposal_mismatch`, `session_mismatch`):

```json
{
  "status": "blocked",
  "error": "Could not discard the staged Hermes proposal: <reason>.",
  "active_proposal_id": "<id or null>",
  "instructions": "Do not claim that a different proposal was discarded."
}
```

### 5.5 `get_hermes_task_status`

Args: `{ "run_id": "<string>" }` (required).

`GET /link/tasks/:id`. Return, mirroring the desktop:

- Terminal status:
  ```json
  { "status": "completed", "run_id": "…", "output": "…",
    "instructions": "The run is finished. Report ONLY what is in `output` above — nothing else." }
  ```
- Still running:
  ```json
  { "status": "running", "run_id": "…",
    "instructions": "The run is STILL IN PROGRESS. There is NO result yet. Tell the user it is still working and stop there — do not guess, predict, or invent any findings. You will receive SYSTEM_EVENT_HERMES_COMPLETE when it finishes." }
  ```
- Could not fetch (network failure, `404 task_unknown`, `500`):
  ```json
  { "status": "error", "run_id": "…", "error": "<what happened>",
    "instructions": "You could not fetch the status. Say exactly that. Do not make up a status or a result." }
  ```

### 5.6 `stop_hermes_task`

Args: `{ "run_id": "<string>" }` (required). `POST /link/tasks/:id/stop`.

```json
{ "status": "stopping", "run_id": "…" }
```

On `404` / `502`, return `{ "status": "error", "run_id": "…", "error": "…" }`.

### 5.7 `approve_hermes_action`

Args: `{ "run_id": "<string>", "choice": "<once|session|always|deny>" }`, both
required.

Only call after the human gate described under `POST /link/tasks/:id/approval`.
If the user has not answered in their own turn, the phone must refuse locally:

```json
{
  "status": "blocked",
  "error": "The user's latest complete response does not explicitly authorize that approval choice.",
  "instructions": "Ask whether to allow this once, for this session, always, or deny it; end your turn and wait."
}
```

Otherwise `POST /link/tasks/:id/approval` and return:

```json
{ "status": "resolved", "run_id": "…", "choice": "once" }
```

`409 approval_not_pending` →
`{ "status": "blocked", "error": "Hermes has no pending approval for this run." }`

### 5.8 `read_hermes_task_result`

Args: `{ "run_id": "<string>" }` — **required on the phone** (the desktop's
version can infer it from what is on screen; there is no screen here).

`GET /link/tasks/:id/result`. Success:

```json
{
  "ok": true, "run_id": "…", "task": "…", "status": "completed",
  "output": "…",
  "instructions": "Answer only from this complete Hermes result."
}
```

`409 task_not_finished`:

```json
{ "ok": false, "run_id": "…", "error": "That Hermes run has not finished.",
  "instructions": "Say it is still working; do not invent a result." }
```

`404 task_unknown` / `404 result_unavailable`:

```json
{ "ok": false, "run_id": "…", "error": "The selected Hermes result could not be restored.",
  "instructions": "Say the result is unavailable; do not invent its contents." }
```

### Tools deliberately NOT declared

`respond_hermes_interaction` (no transport for it — §4), every Iris UI tool
(`control_iris_ui`, `get_iris_ui_context`), the brain/neural-map tools
(`search_brain`, `search_memory`, `read_memory_note`), and `go_to_sleep`. If
the model asks for something in these areas it will simply talk about it; the
system instruction tells it to say that it needs the Mac.

---

## 6. The dispatch gate (reimplement in Swift)

Port of `electron/hermesGate.mjs`. One proposal exists at a time, globally.

### 6.1 State

```
proposal: { id: UUID, task: String, urgency: String, sessionId: String,
            stage: Stage, proposedAt: Date,
            userResponse: String, userTurnObserved: Bool }?

Stage = awaiting_readback | awaiting_user | readback_interrupted
```

TTL: **5 minutes** from `proposedAt`. Every read expires a stale proposal
first, so an expired proposal behaves exactly like `no_proposal`.

### 6.2 Transitions

| Event | Effect |
| --- | --- |
| `propose(task, urgency)` — non-empty task | Replaces any existing proposal with a new one, `stage = awaiting_readback`, `userTurnObserved = false`. Empty task → `{ok:false, reason:"empty_task"}`, proposal untouched. |
| Model turn completes (`turnComplete` with no barge-in) | `awaiting_readback → awaiting_user`. Any other stage: no-op. |
| Model turn interrupted (barge-in / `interrupted`) | `awaiting_readback → readback_interrupted`. Any other stage: no-op. A barge-in does not prove the brief was heard. |
| User turn observed (final input transcript, non-empty) | Records `userResponse`, sets `userTurnObserved = true`. Refused with `not_awaiting_user` when no proposal is staged or the stage is `readback_interrupted`; refused with `readback_in_progress` while still `awaiting_readback`; refused with `empty_response` for blank text. |
| `discard(proposalId)` | Clears the proposal when the id matches. |
| `claim(proposalId)` | Consumes the proposal — see below. |
| Session reset (fresh Live session, not a resume) | Clear the proposal. |

`urgency` is normalized to `low` / `normal` / `high`; anything else becomes
`normal`.

### 6.3 Claim rules

`claim` succeeds only when **all** hold, and it clears the proposal on success:

1. A proposal exists (not expired).
2. `proposalId` matches exactly.
3. `stage == awaiting_user`.
4. `userTurnObserved == true`.

### 6.4 Rejection reasons → what the tool returns

| Reason | `error` | `instructions` |
| --- | --- | --- |
| `no_proposal` | `REJECTED: no active proposal. Stage and read back a complete brief first.` | `Do not claim the task was sent.` |
| `proposal_mismatch` | `REJECTED: proposal_id does not match the exact brief shown to the user.` | With an active proposal: `Do not restage or repeat the readback. Retry submit_hermes_task using active_proposal_id if this is the proposal the user just confirmed.` Otherwise: `Do not claim the task was sent.` |
| `session_mismatch` | `REJECTED: the selected Hermes chat changed. Stage and confirm the brief again.` | `Do not claim the task was sent.` |
| `readback_interrupted` | `REJECTED: the proposal read-back was interrupted. Stage it again and let the full read-back finish before asking for confirmation.` | `Call propose_hermes_task with the corrected brief.` |
| `no_user_turn` | `REJECTED: no distinct response from <UserName> was observed after the proposal read-back.` | `Keep the same proposal staged, end your turn, and wait for the user's response. If their response was not captured, ask one brief natural clarification. Never demand specific confirmation wording.` |

Always include `"active_proposal_id": <current proposal id or null>`.

### 6.5 The settle window

The desktop waits briefly before claiming, because the model can call
`submit_hermes_task` a few milliseconds before the user's final transcript
lands. Mirror it: when the stage is `awaiting_readback` or `awaiting_user` and
`userTurnObserved` is still false, poll every **40 ms** for up to **1.6 s**
before evaluating the claim. This turns a benign race into a success instead of
a spurious `no_user_turn`.

### 6.6 What the gate is not

The gate enforces *ordering and identity*, not vocabulary. It never matches on
"yes" or "do it". The model decides what the user meant and expresses that by
calling `submit_hermes_task` or `discard_hermes_proposal`.

---

## 7. System events the phone injects

Send these as a client text turn (`clientContent`, role `user`,
`turnComplete: true`) — the same mechanism the desktop uses.

### 7.1 Session start

Send once, when the session is ready and before the user has spoken. Skip it if
the user has already started a turn, and skip it on a resumed session.

```
SYSTEM_EVENT_SESSION_START: Greet <UserName> once in one short sentence, then ask what they have in mind. Do not report service status unless asked.
```

(One line; `<UserName>` is `userName` from `/link/status`.)

### 7.2 Hermes completion

Send when a run dispatched by this phone reaches a terminal status. Exact
template (`\n`-joined):

```
SYSTEM_EVENT_HERMES_COMPLETE
run_id: <runId>
status: <status>
instructions_to_iris:
- Tell <UserName> Hermes has returned and summarize the authoritative result below in 1-3 sentences.
- Preserve explicit counts, names, and quantities exactly; if unsure, omit them rather than infer.
- Ask whether to review the details. Do not claim you performed Hermes's work.
authoritative_hermes_result:
<output>
```

- When the session had to be (re)started specifically to deliver this result,
  insert this line immediately after the "Ask whether to review the details…"
  line:
  `- Iris was woken for this result. Deliver it directly without a greeting.`
- When the run produced no text, `<output>` is exactly
  `(Hermes returned no text output.)`
- `<output>` is the run's `output`, or its `error` when it failed. The status
  line carries the failure; do not dress it up.

---

## 8. The announced / undelivered protocol

The problem: a completion must never be lost, and never announced twice, across
backgrounding, reconnects, and a dropped session mid-sentence.

The desktop records who dispatched each run (`origin`). **A run dispatched by a
phone is never spoken by the desktop and never wakes the Mac** — it only
appears as a task card there. The phone owns announcing it, and the desktop
keeps the ledger.

Phone loop:

1. On connect, on foreground, and after any reconnect:
   `GET /link/tasks?undelivered=1`.
2. For each entry (oldest first): fetch the result with
   `GET /link/tasks/:id/result` and inject the `SYSTEM_EVENT_HERMES_COMPLETE`
   turn from §7.2.
3. **Only after the announcement has actually been delivered** — the model's
   turn containing it completed — `POST /link/tasks/:id/announced`.
4. If the session drops, the app is killed, or the user barges in before the
   announcement completes, do **not** acknowledge. Step 1 will return it again
   on the next session, which is exactly the "Announcement interrupted"
   scenario in the dispatch contract.

An acknowledged run never reappears in the undelivered list. Acknowledging an
unknown id returns `404 task_unknown`; this is safe to ignore.

---

## 9. Polling guidance

There is no push. Iris Link exposes state; the phone decides when to look.

| Situation | Cadence |
| --- | --- |
| A run is active and the app is in the foreground | `GET /link/tasks/:id` every **2 s** (the desktop's own interval). |
| Any request fails | Back off: 1 s, 2 s, 4 s, … capped at **30 s**. Keep the run marked "still working"; never downgrade it to failed because *polling* failed. |
| Terminal status observed | Stop polling that run immediately. |
| App backgrounded / resumed | Stop per-run polling; on resume do one `GET /link/tasks` and one `GET /link/tasks?undelivered=1`. |
| No run active | `GET /link/status` no more often than every 5 s (the reachability probe is cached for 5 s anyway). |
| `401 not_paired` | Stop all polling and surface re-pairing. Do not retry in a loop. |

For live activity while foregrounded, `GET /hermes/v1/runs/:id/events` streams
Hermes' SSE through the proxy. It is additive telemetry only — status and
completion must still come from the polling above, exactly as on the desktop.

---

## 10. Behavior the contract requires of the phone

From `openspec/.../agent-dispatch-contract`:

- **Two-step dispatch**: §6, enforced in code — not merely in the prompt.
- **Self-contained briefs**: §5.2 — the brief stands alone; Hermes cannot hear
  the conversation.
- **No invented run state**: §5.5 / §5.8 — speak only from a fetched status or
  a fetched result.
- **Non-blocking dispatch**: `POST /link/tasks` returns a `run_id` immediately;
  the conversation continues while the run works.
- **Proactive completion announcement**: §8, including failures stated plainly.
- **Single pinned agent session**: guaranteed by the desktop — the phone must
  never pass a session id, and must not create runs through
  `POST /hermes/v1/runs`.
- **Secure handling of interaction requests**: approvals through §5.7;
  clarifications, sudo and secrets are refused with "needs attention on the
  Mac" and never spoken.

---

## 11. Push notifications

There *is* push, and it comes from the Mac. The desktop signs an ES256
provider JWT with the team's `.p8` key (kept in `~/.iris`, never sent to a
phone) and posts straight to Apple over HTTP/2 — no relay, no third party.
§9's "there is no push" applies to everything except the two notifications
below; polling is still how the phone learns anything else.

`GET /link/status` carries `"pushConfigured": true|false` — whether this Mac
can push at all. It is a boolean and nothing else. When it is `false`,
registering still succeeds but no notification will ever arrive; say so rather
than promising alerts.

### 11.1 `PUT /link/push-token` — register

Request: `{"token": "<APNs device token, hex>", "environment": "sandbox"|"production"}`

`200` → `{"ok": true, "pushEnabled": true, "environment": "sandbox"}`

Idempotent, and there is exactly **one token per paired device**: registering
again replaces whatever was stored. The token is written next to the device's
credential hash in the desktop's `devices.json`, is never returned by any
route, and is deleted when the device is revoked.

Errors: `400 invalid_token` (not hex, or not a plausible length) ·
`400 invalid_environment` · `400 invalid_json` · `415` for a non-JSON
`Content-Type` · `401 not_paired` · `405 method_not_allowed`.

### 11.2 `DELETE /link/push-token` — unregister

Body: none. `200` → `{"ok": true, "pushEnabled": false}`. Safe to call when
nothing is registered. Call it when the user turns notifications off in Iris.

### 11.3 What the phone must do

1. Ask for notification authorization, then register with APNs and `PUT` the
   token **after the user grants permission** — and again on every
   `didRegisterForRemoteNotificationsWithDeviceToken`, because iOS can issue a
   new token after a restore, a reinstall, or an OS update. Re-`PUT` on every
   launch as well: it is idempotent and costs one request.
2. **Derive `environment` from the build, not from a setting.** A token minted
   under the development entitlement only works against Apple's sandbox host
   and vice versa; sending to the wrong host returns `BadDeviceToken` and the
   Mac drops the token.
   - Debug / run-from-Xcode → `"sandbox"` (`aps-environment: development`)
   - TestFlight / App Store → `"production"` (`aps-environment: production`)
   The conventional derivation is `#if DEBUG` → sandbox, else check whether the
   receipt URL ends in `sandboxReceipt` (TestFlight still uses the production
   APNs host, so TestFlight → `"production"`).
3. On tap, read `run_id` from the payload and open **that run** — fetch
   `GET /link/tasks/:id` and, if terminal, `GET /link/tasks/:id/result`. Never
   speak a result from the notification body; it does not contain one.
4. Keep acking with `POST /link/tasks/:id/announced` (§8). The ack is what
   suppresses a duplicate push: the desktop waits **6 seconds** after a
   phone-dispatched run finishes before pushing, and skips the push entirely if
   the ack has landed by then. A phone that is in a live session therefore
   announces the result itself and the user gets no banner; a phone that is
   asleep gets the banner.
5. Foreground presentation is the phone's choice, but a run the user is already
   hearing about should not also banner.

### 11.4 The two payloads

Both are alert pushes (`apns-push-type: alert`, priority 10) with
`apns-collapse-id` set, so a repeat for the same run replaces the old banner
rather than stacking. Neither ever contains Hermes' output: a lock screen shows
notifications, so the body is the task title only, shortened to ~110
characters.

**A run this phone dispatched finished** — sent once per run, `apns-collapse-id`
= the run id:

```json
{
  "aps": {
    "alert": { "title": "Hermes finished", "body": "<short task title>" },
    "sound": "default",
    "thread-id": "<run id>",
    "interruption-level": "active"
  },
  "run_id": "<run id>",
  "kind": "run_complete"
}
```

The title is the run's **real** terminal status: `Hermes finished`
(`completed`), `Hermes couldn't finish` (`failed` / `error`), or
`Hermes was stopped` (`cancelled` / `canceled`). Do not restate it as success.

**A run this phone dispatched is waiting on the user** — sent at most once per
distinct pending request (a repeated poll of the same request does not push
again; a *different* request on the same run does):

```json
{
  "aps": {
    "alert": { "title": "Hermes needs you", "body": "<short task title> — Open Iris to approve or deny it." },
    "sound": "default",
    "thread-id": "<run id>",
    "interruption-level": "time-sensitive"
  },
  "run_id": "<run id>",
  "kind": "needs_attention",
  "request_id": "<opaque id for this pending request>",
  "can_approve_from_phone": true
}
```

When `can_approve_from_phone` is `false` the body says it needs an answer on
the Mac — that is a Hermes interaction (clarification, sudo, secret), which
Iris Link does not carry (§4). Say it needs the Mac; do not offer to approve
it.

`interruption-level: "time-sensitive"` breaks through Focus and requires the
**Time Sensitive Notifications** capability in the app's entitlements;
completions use `"active"` and do not.

### 11.5 `pending_approval` on the task API

`GET /link/tasks/:id` and every entry of `GET /link/tasks` now carry:

```json
"pending_approval": {
  "request_id": "approval:9f3c…",
  "summary": "Hermes wants to run: rm -rf build",
  "can_approve_from_phone": true
}
```

or `null` when nothing is pending. It is sourced from the desktop's real run
state — an approval Hermes actually asked for, or an interactive prompt that
Link cannot carry — never from a guess. `request_id` matches the one in a
`needs_attention` payload for the same request, so a push and a poll can be
reconciled. A secret prompt never has its question repeated here; the summary
says only that a credential must be entered on the Mac.

`can_approve_from_phone: true` means §5.7 applies: describe it, **end the
turn**, and only call `POST /link/tasks/:id/approval` after the user has
answered in a turn of their own. The push is a nudge, never authorization.

### 11.6 iOS capabilities required

- **Push Notifications** capability, i.e. an `aps-environment` entitlement
  (`development` for Xcode builds, `production` for TestFlight/App Store).
  Without it, `registerForRemoteNotifications()` fails and there is no token.
- **Time Sensitive Notifications** capability for
  `interruption-level: "time-sensitive"` to be honored.
- **No background mode is needed.** Plain alert pushes are displayed by the
  system; the app does not have to be running and does not need
  `remote-notification` in `UIBackgroundModes`. (That mode is only for silent
  content-available pushes, which Iris does not send.)
- Revoking the device on the Mac deletes its token along with its credential,
  so a revoked phone stops receiving pushes immediately. A token Apple reports
  as `Unregistered` or `BadDeviceToken` is dropped by the desktop; the phone
  re-registers to start receiving again.

---

## 12. Live progress

The desktop task card shows what Hermes is doing *right now*: a headline
("Running code"), a step count, and a list of steps with a tool name, a short
preview, a duration and a done/running state. That view used to exist only in
the renderer. `electron/runSteps.mjs` now accumulates the same steps in the
main process from the same normalized Hermes events, so the task API can serve
them to the phone. Desktop source of truth: `electron/runSteps.mjs`
(accumulator + redaction), `src/lib/tasks.ts` + `src/components/WorkCard.tsx`
(the rules it is a port of, pinned by `test/runSteps.test.mjs`).

**Truthfulness.** Only real events are reported. A run that has produced no
events has `"steps": []`, `"step_count": 0` and `"headline": ""`. The desktop
never invents progress, and neither should the phone: with an empty headline,
show the run's status, not a guess.

### 12.1 `GET /link/tasks` — list entries

Every entry in §4's list gains exactly two fields — the list must stay small,
so the step list itself is **never** included here:

```json
{
  "run_id": "…", "task": "…", "status": "running", "…": "…",
  "headline": "Running code",
  "step_count": 7
}
```

### 12.2 `GET /link/tasks/:id` — the full block

The detail response gains the two fields above plus:

```json
{
  "run_id": "run-8f21", "status": "running",
  "headline": "Running code",
  "step_count": 3,
  "steps_cursor": 5,
  "steps_complete": true,
  "steps_truncated": false,
  "steps": [
    {
      "id": "s1",
      "index": 1,
      "tool": "Terminal",
      "category": "code",
      "label": "osascript <<'EOF' tell applica…",
      "preview": "osascript <<'EOF' tell application \"Finder\"",
      "status": "done",
      "started_at": 1758240301000,
      "duration_ms": 1200
    },
    {
      "id": "s3",
      "index": 3,
      "tool": "web_search",
      "category": "search",
      "label": "example.com",
      "preview": "https://www.example.com/search?q=hermes",
      "status": "running",
      "started_at": 1758240304000,
      "duration_ms": null
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `headline` | One line for "what is happening now", in the desktop's own wording: `Running code`, `Searching example.com`, `Browsing news.ycombinator.com`, `Working on plan.md`, `Using weather lookup`. When steps exist but none is running it is `Thinking…`. When nothing has been recorded it is `""`. |
| `step_count` | How many steps are currently retained for the run (at most 60). |
| `steps[].id` | Stable within the run, e.g. `"s3"`. Use it as a list identity. |
| `steps[].index` | The step's creation position — the number inside `id`. Steps arrive in ascending `index` order. |
| `steps[].tool` | The raw Hermes tool name. |
| `steps[].category` | One of `browser`, `search`, `code`, `file`, `tool` — see §12.5. |
| `steps[].label` | The short secondary detail the desktop shows beside the tool name: a host for URLs, a filename for file tools, a one-line snippet (≤ 64 chars) otherwise. May be `""`. |
| `steps[].preview` | The sanitized, redacted, ≤ 200-char raw preview. May be `""`. Display it as untrusted text; never execute or follow it. |
| `steps[].status` | `running`, `done` or `failed`. |
| `steps[].started_at` | Epoch **milliseconds**. |
| `steps[].duration_ms` | Integer milliseconds, or `null` while the step is running. Render like the desktop: `1.2s`. |
| `steps_cursor` | The value to send as `steps_since` on the next poll. |
| `steps_complete` | See §12.4. |
| `steps_truncated` | `true` when older steps were dropped by the 60-step bound. |

### 12.3 `?steps_since=` — fetch only what changed

```
GET /link/tasks/run-8f21?steps_since=5
```

- Send the `steps_cursor` from the previous response. A step **id** (`s5`)
  works too: ids and cursors come from one per-run counter.
- The response contains only steps that were **created or changed** since that
  cursor — a step that merely finished comes back again, with its new `status`
  and `duration_ms`. Merge by `id`: replace a step you already hold, append one
  you do not.
- `step_count`, `headline`, `steps_cursor` and the flags always describe the
  **whole** run, not the delta.
- Omit the parameter (or send something unparseable) to get the full retained
  list. Do that on first load and after any error.

### 12.4 `steps_complete`

`true` only when Iris can vouch that the list is the whole story. It is
`false` when:

- nothing has been recorded for that run yet, **or**
- Iris was restarted while the run was in flight — the steps live in memory
  only, so they are simply gone, **or**
- older steps were evicted by the 60-step bound (`steps_truncated: true`).

On `false` with an empty `steps`, say so plainly: *"Iris doesn't have the step
history for this run — it's still working."* Never imply the run did nothing.
Status, output and completion are unaffected; they come from §4 as always.

### 12.5 Categories → SF Symbols

Mirror the desktop's icons:

| `category` | Desktop icon | SF Symbol |
| --- | --- | --- |
| `browser` | Globe | `globe` |
| `search` | Search | `magnifyingglass` |
| `code` | Code2 | `chevron.left.forwardslash.chevron.right` |
| `file` | FileText | `doc.text` |
| `tool` | Cpu | `cpu` |

Step status: `running` → a spinner or pulsing dot · `done` →
`checkmark` · `failed` → `xmark`.

### 12.6 Polling cadence

Live progress adds no new route, so §9 still governs. Concretely:

| Situation | Cadence |
| --- | --- |
| A run detail screen is open and the run is active | `GET /link/tasks/:id?steps_since=<cursor>` every **2 s** (the same request that already carries status — do not poll twice). |
| A run list is on screen | `GET /link/tasks` every **5 s**. `headline` + `step_count` are enough for a list row; never fetch each run's detail to fill a list. |
| Backgrounded | Stop. On resume, one full `GET /link/tasks/:id` **without** `steps_since` to resynchronize. |
| Terminal status observed | One last fetch (to capture the final step states), then stop. |
| Any failure | Back off per §9 and keep the steps you already have; a failed poll is not a step that failed. |

Steps for a finished run stay answerable for about **10 minutes**, then are
evicted and the run reports `steps_complete: false`. Fetch the result (§4)
rather than relying on steps after that.
