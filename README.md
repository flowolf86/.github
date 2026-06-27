# flowolf86/.github — shared governance for all repos

Single source of truth for CI, PR/branch/merge rules, release flow, conventions,
and lessons learned across every `flowolf86` repo. Replaces the copy-pasted
governance that used to live (and drift) in each repo.

This repo is **public** so its reusable workflows are callable from the private
app repos without any cross-repo access setup. It contains no secrets.

## What lives here

| Path | Purpose | How it reaches the other repos |
|---|---|---|
| `.github/workflows/app-ci.yml` | Reusable 4-job app CI (Postgres gate, mypy, coverage, e2e) | `uses:` — caller passes `app_name` |
| `.github/workflows/app-release.yml` | Reusable release → GHCR build + VPS deploy | `uses:` |
| `.github/workflows/app-bump-foundation.yml` | Reusable foundation-submodule bump-to-tag PR | `uses:` |
| `.github/workflows/pull-standards.yml` | Reusable: each repo pulls `standards/` into its `.standards/` & opens a PR (token-free, built-in GITHUB_TOKEN) | `uses:` from each repo |
| `standards/CONVENTIONS.md`, `LESSONS.md` | The human + AI-agent rules and traps | synced → each repo's `.standards/`, `@import`ed by `CLAUDE.md` |
| `standards/CLAUDE.snippet.md` | Block to paste into each repo's `CLAUDE.md` | manual, once |
| `CONTRIBUTING.md`, `CODEOWNERS`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/ISSUE_TEMPLATE/*` | Default community-health files | auto-applied by GitHub to all repos |
| `rulesets/app-master.json` + `apply-rulesets.sh` | Server-side branch protection (Pro) | run the script |
| `githooks/pre-push` + `install.sh` | Client-side no-push-to-master (works on Free) | run per clone |

## Which repos use what

- **beikost-app, packliste-app** — call all three reusable workflows + standards + hooks.
- **foundation-api-engine** — keeps its own CI (it *is* the engine, no submodule);
  adopts community-health + standards + hooks.
- **labs-infra** — keeps its lighter CI; adopts community-health + standards + hooks.

## Plan portability

Everything works on GitHub **Free** except server-side rulesets on private repos.
Those are layered on top (run `apply-rulesets.sh` while on Pro) and degrade
cleanly — the client-side `pre-push` hook is the always-on backstop, so cancelling
Pro changes nothing in the daily workflow.

## One-time setup

1. Push this repo to `github.com/flowolf86/.github` (public).
2. In each repo add a thin `sync-standards.yml` caller of `pull-standards.yml`
   (with `permissions: contents/pull-requests: write`) — token-free, no secret.
3. In each app repo, swap its workflows to thin callers, paste the CLAUDE snippet,
   and run `githooks/install.sh`.
4. (Pro) run `rulesets/apply-rulesets.sh`.
