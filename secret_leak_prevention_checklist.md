# Secret leak prevention — checklist

What is already done, what only you can do (GitHub settings), and what to do if a real key ever lands in a commit. Repo: `natea/iris` (public).

## Already done (2026-09-23)

- [x] Alert #1 investigated: the flagged `AIza…` string was a fabricated test fixture, not the configured key, and Google rejects it. Resolved as *used in tests*.
- [x] `test/hermesFailure.test.mjs` builds the fake at runtime so no key-shaped literal exists in the source (commit `6498933`).
- [x] Versioned pre-commit hook `.githooks/pre-commit` runs gitleaks over staged changes and refuses the commit on a hit; `.gitleaks.toml` allowlists the three obviously fake fixtures (commit `9f694e2`). Enabled in this clone with `git config core.hooksPath .githooks`.
- [x] `.env` and `.env_test*` are in `.gitignore`; real keys live only in `~/.iris/.env` (mode 0600).
- [x] GitHub *Secret scanning* and *Push protection* are enabled on the repo (confirmed via API).

## You: local machine

- [x] `brew install gitleaks` — installed 8.30.0 on 2026-09-23; the hook scans every commit in this clone.
- [x] Full-history scan run (92 commits): eight hits, all test fixtures, checked by hand and allowlisted by exact value (commit `d5beb1f`). Clean since.
- [ ] In every other clone or worktree of this repo: `git config core.hooksPath .githooks`. (`~/.herdr/worktrees/iris/*` and `.claude/worktrees/*` share the main clone's config only if they were created from it with `git worktree add`; check with `git config --get core.hooksPath` inside each.)

## You: GitHub → natea/iris → Settings → Advanced Security

Checked 2026-09-25: **Secret Protection** and **Push protection** are both enabled, and that is everything GitHub offers a personal-account public repo. *Non-provider patterns* and *validity checks* belong to the paid Secret Protection add-on, which is organizations-only — the API exposes the fields but will not enable them here. The local gitleaks hook covers the generic-pattern gap those would have filled (its default rules flag generic API keys, private keys, JWTs and auth headers, as the history scan showed).

- [x] Secret Protection: enabled.
- [x] Push protection: enabled. Do not grant bypass to anyone.
- [x] **Branch ruleset on `main`** — "Protect main", active (2026-09-25): pull request required (0 approvals — a solo repo cannot self-approve), force pushes blocked, deletions restricted, no bypass actors. Issue → PR → merge is now the only path in; a gitleaks Action can later be added as a required check.
- [x] Notifications checked (2026-09-25): Dependabot alerts → on GitHub, Email, CLI; Watching → Email. Secret-scanning alerts have no separate row on a personal account — they go to repo admins through these, which are on.
- [ ] Optional: Dependabot alerts (Settings → Advanced Security). Not a leak control; cheap.
- [ ] Optional, stronger: a `gitleaks/gitleaks-action` workflow on pull requests, then make it a required check in the ruleset. The hook protects your machine; this protects the repo from any clone that skipped the hook.

## Rules for the code (already in AGENTS.md — repeated here because this is the leak surface)

- Never write a real-looking secret in a test or a doc, even a fake one. Build fixtures at runtime (`"AIza" + "Sy" + …`) or use strings that cannot match a provider pattern (`hunter2-not-a-real-key`).
- Never log a token, a resume handle, or a credential. The desktop's `/link/*` routes and the phone's `LinkClient` already redact; keep it that way.
- Secrets travel through `~/.iris/.env` and the Keychain only. Nothing under the repo, not even in `openspec/`.

## If a real key does land in a commit

Order matters: rotate first, clean second.

1. **Rotate it immediately** at the provider (Google AI Studio for `GEMINI_API_KEY`; Hermes' own config for `API_SERVER_KEY`; Apple Developer for the APNs `.p8`). Assume it was scraped the moment it was pushed — public repos are crawled within minutes.
2. Update `~/.iris/.env` (and `~/.hermes/.env` for the shared key — both files, see memory note) and restart the desktop app; the main process does not hot-reload.
3. Only then rewrite history: `git filter-repo --replace-text <(echo 'THE_KEY==>[removed]')`, force-push every affected branch, and tell anyone with a clone or worktree to re-clone. Check `git worktree list` first — a rewrite under an active worktree breaks it.
4. Resolve the GitHub alert as *revoked*, not *false positive*.
5. GitHub keeps the old commit reachable by SHA until its garbage collection runs; open a support ticket to purge it if the key was high-value.
