## 1. Vocabulary

- [x] 1.1 Write `scripts/github-labels.mjs` with the 48 labels (Conor's names, colours, descriptions verbatim; `ai-shippable` at risk ≤ 2) and run it with `gh label create --force` against `natea/iris` — verify `gh label list` shows all groups and a second run reports no changes — _48 labels (the source enumerates 48, not 52); second run changed nothing_
- [x] 1.2 Review `AGENTS.md` (written with the proposal) against the created labels and the template; fix any mismatch — verify every label group named in the file exists on the repo

## 2. Template and skills

- [x] 2.1 Add `.github/ISSUE_TEMPLATE/work.md` with the ten sections (Context & motivation, Current state, Proposed change, Contract, Blast radius, Implementation steps, Side-fixes, Definition of done, Verification with "Needs a physical iPhone: yes/no", Key files) and a config that makes it the default — verify `gh issue create --web` opens it pre-filled — _On main since #11; GitHub serves `.github/ISSUE_TEMPLATE/work.md` and `config.yml` (verified via the contents API, 2026-09-25)_
- [x] 2.2 Add `.claude/skills/feature-kickoff/SKILL.md`: fetch the issue, refuse `clarity:1–3` and `needs-design` with the questions posted as a comment, read the key files, write the plan, create branch `issue-<n>-<slug>` (worktree when another lane is active), comment "Starting" — verify against a scratch issue — _Written; exercised for real in 3.2_
- [x] 2.3 Add `.claude/skills/issue-drift-sync/SKILL.md`: list commits since a date and open PRs, match `#n` / `Closes #n` against open issues, list issues whose key files changed since they were filed, list issues missing a mandatory label group, report only — verify it flags a deliberately drifted scratch issue — _Written; exercised for real in 3.3_
- [x] 2.4 Add `.claude/skills/session-handoff/SKILL.md`: comment done / not done / next on the active issue, tick matching OpenSpec tasks, note anything that needs the human (device test, restart the Mac app) — verify the comment and the tick land — _Written; exercised for real in 3.2_

## 3. Seed and prove

- [x] 3.1 File the first issues from the open tasks that meet the bar: `add-ios-idle-sleep-and-siri-wake` 2.1–2.3 and 3.1 (lane 3), `migrate-to-gemini-3-8-live` 1.1 and 2.1 (lane 1), `add-ios-voice-companion` 2.6 (lane 1, `serial` if it touches the Link contract); label each honestly and add `(#n)` to its task line — verify each issue is `ai-shippable` only if it truly is — _Issues #1–#7. Three met the bar (#1, #2, #5); #3, #6, #7 are clarity 3 with the open decision stated; #4 is clarity 4 but risk 3. Task lines carry the numbers_
- [x] 3.2 Run one `ai-shippable` lane-3 issue with `feature-kickoff` in a worktree while a lane-1 issue is also in progress — verify no shared files, the PR carries `Closes #n` and the verification it ran, and the human merge ticks the task — _Issue #8 → `feature-kickoff` in worktree `../iris-issue-8` while lane-1/3 work was live in the main tree → PR #9 with `Closes #8` and the un-run device step named → reviewed (2 MEDIUM fixed) → merged; #8 auto-closed and the on-device result was recorded on it_
- [x] 3.3 Run `issue-drift-sync` after the first merges — verify it reports nothing on a clean tracker and something when a task is ticked without an issue — _First run after the merges: 41 pre-workflow commits without `#n` (expected), no unlabelled or dishonest `ai-shippable` issues, no OpenSpec↔tracker mismatch. Two false positives fixed in the skill: check 2 counted the commit that first added a key file, and `date -v` is BSD-only_

## 4. Close the loop

- [x] 4.1 Add the workflow to `README.md` (one paragraph pointing at `AGENTS.md`) — verify a new contributor can find the tracker rules from the README
- [ ] 4.2 Record in design.md what did not work in the first two weeks (labels unused, sections skipped) and trim — verify the template and taxonomy reflect actual use, not the source post — _Needs two weeks of use_
