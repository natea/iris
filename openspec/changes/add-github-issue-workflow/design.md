## Context

See proposal.md — Why. Sources: conor.fyi/llm/github-labels-skill (the taxonomy and the idempotent `gh label create … --force` pattern) and conor.fyi/writing/working-april-26 (the workflow, the ten-section issue, the three skills, the parallel/serial execution loop).

State of this repo: no `AGENTS.md` or `CLAUDE.md` before this change; `.claude/skills/` holds only the six OpenSpec skills; `natea/iris` has GitHub's ten default labels and no open issues; planning lives in four OpenSpec changes with ~45 open tasks between them.

## Goals / Non-Goals

**Goals:**
- An agent can answer "may I take this?" from labels alone.
- Two agents in different lanes never edit the same files.
- What was verified is always stated, and device-only verification is never implied.
- OpenSpec stays the design home; GitHub is the queue. Neither pretends to be the other.

**Non-Goals:**
- Automating issue creation from the phone (later change).
- CI, PR checks, auto-merge. The human merges.
- Replacing OpenSpec tasks with issues. Tasks remain the plan; issues are the queue.

## Decisions

### 1. Take the taxonomy verbatim, then fix the one inconsistency

Names, colours and descriptions are Conor's exactly, so his posts and skills remain the documentation. His two sources disagree on the `ai-shippable` bar (label description: risk ≤ 2; essay: risk ≤ 3). We use the label's text — risk ≤ 2 — because the label is what an agent reads, and the stricter bar is the safer default in a repo where a one-line change to the dispatch gate is `risk:5`.

Alternative: invent an Iris-specific taxonomy. Rejected — the value is in a vocabulary someone else already wrote down and explained.

### 2. Labels via a script, not a skill

`scripts/github-labels.mjs` holds the table and runs `gh label create --force` for each, printing created/updated. A script is diffable, reviewable and runs in CI later; Conor's interactive skill (pick groups from a numbered list) is for someone applying the taxonomy to many repos, which we are not.

### 3. Lanes are fixed by directory, not per project phase

Conor assigns lanes per initiative. Iris's code splits naturally by process boundary and the boundaries are stable, so lanes are constant: 1 `electron/`, 2 `src/`, 3 `ios/IrisLivePrototype` app target, 4 `IrisWidgets` + Live Activity, 5 docs/tests/scripts. The contract files are the only shared surface, so any change to `LINK_API.md`, `hermesTools.mjs` or `mobileSession.mjs`'s token config is `serial` by rule, not by judgement. A worktree per lane (`git worktree add ../iris-lane-3 …`) is the mechanism; the Lattice/worktree tooling already present on the machine is compatible but not required.

### 4. OpenSpec is upstream of issues

A change's `tasks.md` is the plan; an issue is a task (or a coherent bundle of them) made ready for an agent: context, key files, definition of done, labels. The link is textual both ways (`(#123)` on the task line; the change path in the issue). The `issue-drift-sync` skill checks both directions. No generator: issues need judgement about clarity and risk that a script would fake.

Alternative: one issue per task, generated. Rejected — half of the open tasks are `clarity:3` verification items that should not be queued as if shippable.

### 5. Skills are thin and repo-specific

Each is a `SKILL.md` under `.claude/skills/`, under a page, consisting of the `gh` commands and the checklist — the repo knowledge lives in `AGENTS.md`, which the skills reference rather than repeat. `feature-kickoff` refuses `clarity:≤3` and `needs-design`; `session-handoff` always writes to the issue and to the OpenSpec task ticks; `issue-drift-sync` is read-only and reports.

### 6. Verification honesty is structural

The issue template's *Verification* section has a required line: "Needs a physical iPhone: yes/no". `AGENTS.md` says a PR must name any verification step it could not run. This is the one place the workflow is stricter than Conor's, because in this repo the difference between "tests pass" and "works on the phone" has bitten repeatedly (glass swallowing taps, the static-dispatch bug, the push crash).

## Risks / Trade-offs

- [Labels applied inconsistently] → the six mandatory groups are stated in AGENTS.md and the template; the drift skill reports issues missing a group.
- [Tracker becomes a second plan that diverges from OpenSpec] → decision 4 and the drift skill; tasks tick when the issue's PR merges.
- [Agents take work that looked shippable but was not] → clarity is set by a human; an agent that finds the issue wrong comments and stops rather than improvising (AGENTS.md).
- [52 labels feel heavy for a one-person repo] → they cost nothing unused; sequencing and lane labels are only added when scheduling parallel work.

## Migration Plan

1. Run the label script. 2. Commit `AGENTS.md`, the template, the skills. 3. Seed the tracker: turn the `ai-shippable`-grade open tasks in the three current changes into issues (design.md of each names them). 4. Run one lane in a worktree end to end. Rollback: delete the labels; the files are inert.

## Open Questions

- Whether Hermes should get `gh issue create` in its tool allowlist so "Iris, file that as an issue" works from the phone. Deferrable; separate change.
