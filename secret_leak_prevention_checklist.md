# Secret leak prevention — checklist

What is already done, what only you can do (GitHub settings), and what to do if a real key ever lands in a commit. Repo: `natea/iris` (public).

## Already done (2026-09-23)

- [x] Alert #1 investigated: the flagged `AIza…` string was a fabricated test fixture, not the configured key, and Google rejects it. Resolved as *used in tests*.
- [x] `test/hermesFailure.test.mjs` builds the fake at runtime so no key-shaped literal exists in the source (commit `6498933`).
- [x] Versioned pre-commit hook `.githooks/pre-commit` runs gitleaks over staged changes and refuses the commit on a hit; `.gitleaks.toml` allowlists the three obviously fake fixtures (commit `9f694e2`). Enabled in this clone with `git config core.hooksPath .githooks`.
- [x] `.env` and `.env_test*` are in `.gitignore`; real keys live only in `~/.iris/.env` (mode 0600).
- [x] GitHub *Secret scanning* and *Push protection* are enabled on the repo (confirmed via API).

## You: local machine

- [ ] `brew install gitleaks` — until this is installed the hook prints a warning and lets the commit through. It does not scan.
- [ ] `gitleaks git --no-banner --redact` from the repo root once, to scan the whole history for anything else key-shaped. Expect the `.md` and `openspec/` allowlist to keep documentation examples quiet.
- [ ] In every other clone or worktree of this repo: `git config core.hooksPath .githooks`. (`~/.herdr/worktrees/iris/*` and `.claude/worktrees/*` share the main clone's config only if they were created from it with `git worktree add`; check with `git config --get core.hooksPath` inside each.)

## You: GitHub → natea/iris → Settings → Code security

The API would not toggle these on this repo, so they are clicks:

- [ ] **Secret scanning → Non-provider patterns: Enable.** Catches generic key shapes (`API_KEY=…`, private keys, JWTs) that have no vendor pattern. This is the one that would have caught `API_SERVER_KEY` if it were ever pasted.
- [ ] **Secret scanning → Validity checks: Enable.** GitHub asks the provider whether a found key is live, so the next alert says *active* or *inactive* instead of *unknown*. Alert #1 said *unknown*; this would have said *inactive* immediately.
- [ ] **Push protection: confirm Enabled** (it is, per API) and **do not grant bypass** to anyone. Bypass is the setting that turns a hard stop into a warning.
- [ ] **Secret scanning → Alerts → notify:** make sure your account has *Security alerts* email on for this repo (Settings → Notifications → "Security alerts"), so an alert does not sit for a day as #1 did.
- [ ] **Dependabot alerts / security updates: Enable** (currently disabled). Not a leak control, but it is on the same page and cheap.
- [ ] **Branch protection on `main`** (Settings → Branches → Add rule): require a pull request before merging, and *Require status checks* once a scanning action exists (below). This is what stops a direct push from bypassing review.
- [ ] Optional, stronger: **Actions → add a gitleaks workflow** (`gitleaks/gitleaks-action`) on pull requests, then make it a required status check. The pre-commit hook protects your machine; this protects the repo from any clone that skipped the hook.

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
