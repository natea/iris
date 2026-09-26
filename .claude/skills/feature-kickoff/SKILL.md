---
name: feature-kickoff
description: Start work on a GitHub issue from natea/iris — fetch it, refuse it if it is not ready, read its key files, plan, branch, and announce. Use when the user says "kick off #N", "start issue N", or "pick up the next ai-shippable issue".
---

# feature-kickoff

The rules are in `AGENTS.md`; this is the checklist that applies them. Input: an issue number, or none (then pick from `ai-shippable`).

## 1. Fetch

```bash
gh issue view <n> --repo natea/iris --json number,title,body,labels,state,comments
gh issue list --repo natea/iris --label ai-shippable --state open --json number,title,labels   # when no number given
```

## 2. Refuse what is not ready — before reading any code

- `clarity:1`, `clarity:2`, `clarity:3`, or `needs-design`: do not start. Post one comment listing the questions that would raise it to clarity 4, then stop:
  ```bash
  gh issue comment <n> --repo natea/iris --body-file questions.md
  ```
- Missing any of the six mandatory label groups (priority, clarity, risk, blast, size, type): comment that it is unlabelled and stop.
- `serial` while another issue is in progress in any lane: stop and say which.
- Lane already busy (another branch `issue-*` in that lane's directories has uncommitted or unpushed work): stop and say which.

## 3. Read

Read every path under **Key files** in full, then the files the **Blast radius** names. If the issue's *Current state* is wrong about the code, comment with the correction and ask whether the plan still holds. Do not silently re-plan.

## 4. Plan

Write the plan as a short comment: the steps you will take, in order, and the verification you will run — and which verification steps you cannot run (physical iPhone, Mac restart). Keep it under twenty lines.

## 5. Branch

```bash
git switch -c issue-<n>-<slug> main
# When another lane is active on this machine, use a worktree instead:
git worktree add ../iris-issue-<n> -b issue-<n>-<slug> main
```

## 6. Announce

```bash
gh issue comment <n> --repo natea/iris --body "Starting on branch issue-<n>-<slug>. Plan above."
```

Do not change labels or assignees. Then implement. When you stop, run `session-handoff`.
