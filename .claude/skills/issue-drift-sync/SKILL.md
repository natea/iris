---
name: issue-drift-sync
description: Read-only check that the natea/iris tracker still matches the code — commits and PRs without issues, issues whose key files moved, issues missing mandatory labels, OpenSpec tasks ticked without an issue. Use when the user says "drift check", "is the tracker in sync", or before a planning session.
---

# issue-drift-sync

Reports only. Never edits an issue, a label, a task file or a commit. Output is a short markdown report the human acts on.

## Gather

```bash
SINCE=${SINCE:-"14 days ago"}   # a git date phrase, so it works with BSD and GNU date
gh issue list --repo natea/iris --state open --limit 200 --json number,title,labels,body,createdAt
gh pr list --repo natea/iris --state all --limit 100 --json number,title,body,state,mergedAt,headRefName
git log --since="$SINCE" --format='%h %s' main
```

## Checks

1. **Work without an issue.** Commits on `main` since `$SINCE` whose subject and body carry no `#n`, and open or merged PRs whose body has no `Closes #n` / `Fixes #n`. List them.
2. **Issues whose ground moved.** For each open issue, take the paths under **Key files** and **Blast radius**; if any was *modified* on `main` after the issue's `createdAt` (`git log --since=<createdAt> --diff-filter=M -- <path>` — a commit that merely added the file, e.g. an OpenSpec design committed after the issue cited it, is not drift), list the issue and the commits. Its *Current state* may now be wrong.
3. **Unlabelled.** Open issues missing any of: `P*`, `clarity:*`, `risk:*`, `blast:*`, `size:*`, `type:*`.
4. **Dishonest `ai-shippable`.** Open issues with `ai-shippable` whose clarity is below 4 or risk above 2.
5. **OpenSpec ↔ tracker.** In every `openspec/changes/*/tasks.md` (not `archive/`): a `- [x]` task line with `(#n)` whose issue is still open; and an open issue that names a change whose matching task is still `- [ ]` after the issue's PR merged.
6. **Stale lanes.** Branches `issue-*` with no commit in 14 days and an open issue.

## Report

One section per check, only the ones with findings, each finding one line with the issue or PR number and what to do (`close`, `relabel`, `update Current state`, `tick task`, `file issue`). End with "Clean" if nothing was found.
