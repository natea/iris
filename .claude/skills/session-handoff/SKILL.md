---
name: session-handoff
description: Leave work on a natea/iris issue in a state another agent can resume — comment done / not done / next on the issue, tick the matching OpenSpec tasks, and say what needs the human. Use when stopping for any reason mid-issue, or when the user says "hand off", "wrap up", or "leave a note".
---

# session-handoff

Run before stopping, whether the work is finished or not. Two writes, both required.

## 1. Comment on the issue

Three headings, each a short list. Facts only; nothing "should" work that was not run.

```markdown
**Done**
- <what landed, with commit SHAs on branch issue-<n>-<slug>>

**Not done**
- <what remains from the issue's Implementation steps>

**Next**
- <the single next step; the command to run first>

**Needs the human**
- <device test / restart the Mac app / a decision — or "nothing">
```

```bash
gh issue comment <n> --repo natea/iris --body-file handoff.md
```

If the PR is open, the same text goes in the PR description under *Verification*, naming any step that could not be run.

## 2. Tick OpenSpec tasks

If the issue names an OpenSpec change, find the task lines carrying `(#n)` in `openspec/changes/<change>/tasks.md` and mark `- [x]` only those whose *specified behaviour* is complete and verified. Partial stays `- [ ]` with nothing added to the line. Commit the tick with the code, not separately.

## 3. Leave the tree resumable

- Commit or stash; never leave uncommitted work in a shared worktree.
- Push the branch if the user allows pushes; otherwise say in the comment that it is local only.
- Do not close the issue, change labels, or merge.
