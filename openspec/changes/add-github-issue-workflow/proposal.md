## Why

Work on Iris is planned well (OpenSpec changes with tasks) but queued badly: a task lives in a `tasks.md`, a bug found on the phone lives in a chat transcript, and nothing tells an agent which item it may take, how careful to be, or whether another agent is already in the same files. Conor Luddy's workflow (conor.fyi, "github-labels-skill" and "working-april-26") solves exactly this: GitHub issues written so "another agent with zero context can pick it up and run with it", and a label taxonomy that works as "a protocol that lets AI agents pick up issues, assess safety, and ship code with minimal human input." Iris has three lanes that rarely overlap (desktop, phone, widgets) and a human who tests on a physical iPhone — the same shape as his iOS work.

## What Changes

- **`AGENTS.md` at the repo root** (written alongside this proposal): how the tracker works, the label taxonomy, the rules for taking an issue (`clarity:4+` only; one per lane; `serial` alone), how to file one, how to finish, and what agents never do (change labels, merge, dispatch to Hermes unasked).
- **Labels created on `natea/iris`** with an idempotent script: priority `P1–P5`, `clarity:1–5`, `risk:1–5`, `blast:1–5`, `size:XS–XL`, `parallel:1–5` + `serial`, `seq:01–10`, `type:*`, `ai-shippable`, `needs-design` — Conor's names, colours and descriptions verbatim, so the vocabulary is the one his skills and writing already document. The ten GitHub defaults stay; `bug`/`enhancement` are left for humans who reach for them and map to `type:bug`/`type:feature`.
- **An issue template** (`.github/ISSUE_TEMPLATE/work.md`) with his ten sections, adapted: *Model/API spec* becomes *Contract* (does this touch `LINK_API.md` or `hermesTools.mjs`?), and *Verification* gains a "needs a physical device" checkbox because that is the recurring truth-telling problem here.
- **Three repo skills**, ported from his and pointed at this repo's structure:
  - `feature-kickoff`: given an issue number, fetch it, read its key files, confirm the clarity label is honest, produce a plan, create the branch/worktree, comment "Starting".
  - `issue-drift-sync`: compare recent commits and open PRs to open issues; flag issues whose work landed without `Closes`, PRs with no issue, and issues whose code moved under them.
  - `session-handoff`: when stopping, comment on the issue with done / not done / next, and update the OpenSpec task ticks.
- **OpenSpec ↔ issues, one direction.** An OpenSpec change is where design happens; issues are how its tasks are queued. A `tasks.md` line may carry `(#123)`; an issue may name `openspec/changes/<name>`. A task that is not yet an issue is not yet queued. No sync tooling — a rule and a drift check.
- **Lanes fixed for this repo**: 1 `electron/`, 2 `src/`, 3 iOS app, 4 widgets/Live Activity, 5 docs/tests/scripts; `LINK_API.md` and shared tool schemas are `serial`.
- **Not adopted**: the Raspberry Pi / WhatsApp capture loop. The equivalent here is simpler — the human tells Iris on the phone, and a Hermes brief opens the issue — and is a later, separate change once Hermes has `gh` in its allowlist.

## Capabilities

### New Capabilities
- None. This is process and tooling; no Iris runtime behaviour changes. `skip_specs: true`.

### Modified Capabilities
- None.

## Impact

- **New files**: `AGENTS.md`, `scripts/github-labels.mjs`, `.github/ISSUE_TEMPLATE/work.md`, `.claude/skills/{feature-kickoff,issue-drift-sync,session-handoff}/SKILL.md`.
- **External**: labels on `github.com/natea/iris` (48 created). Needs `gh` authenticated with write access to the repo.
- **Existing OpenSpec changes**: the open tasks in `add-ios-voice-companion`, `add-ios-idle-sleep-and-siri-wake` and `migrate-to-gemini-3-8-live` become the first issues, which is also the proving run for the template and labels.
- **Risk**: label sprawl and stale issues. The drift skill and the "one issue per lane" rule are the mitigation; if the tracker goes quiet the labels cost nothing.
