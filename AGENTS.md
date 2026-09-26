# Working on Iris

Iris is a voice assistant: an Electron desktop app (`electron/`, `src/`) that runs a Gemini Live session and dispatches work to a local Hermes agent, and an iOS companion (`ios/IrisLivePrototype`) that pairs with the desktop over Tailscale. Design lives in `openspec/` (proposals, specs, tasks); day-to-day work is tracked as GitHub issues at https://github.com/natea/iris/issues.

This file is for any agent working in this repository. It says how work is queued, how to tell whether an issue is yours to take, and what to leave behind.

## The tracker

Issues are the queue. An issue is written so that an agent with zero context can pick it up and finish it — if it cannot be, it is not ready and its labels say so. Labels are the protocol: they tell you priority, whether the ask is clear enough to act on, how careful the PR must be, how much of the codebase it touches, how big it is, and whether it can run beside other work.

Use `gh` for everything below. The repo is `natea/iris`.

### Labels

Every issue carries one label from each of the first five groups. Parallelism and sequencing are added when work is being scheduled.

| Group | Labels | Meaning |
|---|---|---|
| Priority | `P1` … `P5` | P1 must ship first and blocks other work; P5 is nice to have. |
| Clarity | `clarity:1` … `clarity:5` | 1 is a vague idea; 3 is direction known, details TBD; 4 is a clear spec with minor ambiguities; 5 is crystal clear with a full definition of done. |
| Risk | `risk:1` … `risk:5` | How much scrutiny the PR needs. 1 is isolated and hard to break; 3 touches shared code; 5 is a data-model, navigation-architecture or seed-data change. |
| Blast radius | `blast:1` … `blast:5` | How much it touches. 1 is one file; 2 is one feature folder; 3 crosses domains; 4 is architectural; 5 is full-stack (desktop + phone + Link contract). |
| Size | `size:XS` … `size:XL` | Effort. Anything above `size:M` should be decomposed before it is picked up. |
| Type | `type:bug` `type:feature` `type:refactor` `type:chore` `type:spike` | What kind of change. |
| Parallelism | `parallel:1` … `parallel:5`, `serial` | A lane. Issues in different lanes do not touch the same files and can run at once in separate worktrees. `serial` touches two or more lanes and runs alone. |
| Sequence | `seq:01` … `seq:10` | Order. All `seq:01` issues before any `seq:02`. |
| Flags | `ai-shippable`, `needs-design` | `ai-shippable` = clarity 4 or 5, risk 2 or lower, and a definition of done: take it without asking. `needs-design` = do not start; it needs a human decision or an OpenSpec proposal first. |

Risk and blast are independent: a safe refactor across many files is `risk:1 blast:3`; a one-line change to the dispatch gate is `risk:5 blast:1`.

Lanes for this repo, when they are needed: **1** `electron/` main process and Iris Link; **2** `src/` renderer; **3** `ios/IrisLivePrototype` app; **4** `IrisWidgets` and Live Activity; **5** docs, tests, scripts. A change to `LINK_API.md` or `hermesTools.mjs` is `serial` — both halves read it.

### Picking up work

1. Find candidates:
   ```bash
   gh issue list --repo natea/iris --label ai-shippable --state open
   gh issue list --repo natea/iris --label seq:01 --state open   # when sequencing is in use
   ```
2. Take only `clarity:4` or `clarity:5`. A `clarity:3` or lower issue needs a human: comment with the questions and stop. Never guess your way through a `clarity:2`.
3. Take only one issue per lane at a time. If it is `serial`, make sure nothing else is in flight.
4. Read the whole issue, then the files it names under *Key files*. If the issue is wrong about the code, say so in a comment before changing the plan.
5. Work in a branch named for the issue (`issue-123-short-slug`), in its own worktree when another lane is active.
6. Assign yourself by commenting what you are doing (`gh issue comment 123 --body "Starting: …"`). Do not change labels; the human sets them.

If an issue names an OpenSpec change (`openspec/changes/<name>`), that change's `tasks.md` is the work list and the issue is the tracker entry for one or more of its tasks. Tick tasks there as you go.

### Filing an issue

Anyone — a human, or an agent that found something while doing other work — files issues. An issue is for a unit of work, not a discussion; a discussion is an OpenSpec proposal. Use the template (`.github/ISSUE_TEMPLATE/work.md`) and fill every section:

- **Context & motivation** — what is wrong or wanted, and why now.
- **Current state** — what the code does today, with `file:line`.
- **Proposed change** — what to do. Say what *not* to do if it is tempting.
- **Blast radius** — files and modules that will change.
- **Implementation steps** — ordered, small.
- **Side-fixes** — things noticed nearby that should be fixed in the same PR, or explicitly deferred.
- **Definition of done** — observable behaviour, not "implemented".
- **Verification** — how to prove it: test command, device steps, or what to look at.
- **Key files** — the reference list an agent reads first.

Then label it: one from each of priority, clarity, risk, blast, size, type. Add `ai-shippable` only if it honestly meets the bar. An agent filing an issue leaves clarity at what it *is*, not what it hopes.

```bash
gh issue create --repo natea/iris --title "…" --body-file issue.md \
  --label P3 --label clarity:4 --label risk:2 --label blast:2 --label size:S --label type:bug --label ai-shippable
```

### Finishing

- Open the PR with `Closes #123` in the body and the verification you actually ran. If a step in the issue's verification plan could not be run (needs a physical device, needs the Mac app restarted), say which and why — do not imply it passed.
- Before opening the PR, re-read the issue: if the work drifted from it, either bring the code back or update the issue and say what changed.
- Leave a short comment on the issue when you stop mid-way: what is done, what is not, the next step. Another agent may pick it up.
- The human reviews, tests on device, and merges. Do not merge.

### What agents must not do here

- Change labels, close issues, or merge PRs. Those are the human's.
- Dispatch work to Hermes, mint tokens, or touch `~/.iris` on the human's machine without being asked.
- Commit or push unless the task says to. Many tasks here are diagnose-first.

## Repository conventions

- Desktop tests: `npm test`. iOS: `xcodebuild test -project ios/IrisLivePrototype/IrisLivePrototype.xcodeproj -scheme IrisLivePrototype -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`. On-device behaviour (audio routing, push, Live Activity) can only be verified on a real iPhone; say so rather than claiming it.
- The Electron main process does not hot-reload. `/link/status` carries a build stamp; check it before concluding the Mac "didn't pick up" a change.
- `ios/IrisLivePrototype/LINK_API.md` is the contract between the desktop and the phone. Changes to it are `serial` and need both sides.
- Commit messages say what changed and why in plain prose, and record what was verified and against what.
- Design first for anything with `needs-design`: `openspec/changes/` is where proposals live; `/opsx:propose` creates one.
