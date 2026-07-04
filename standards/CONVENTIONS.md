# Conventions

Canonical working rules for every repo under `flowolf86`. The source of truth is
`flowolf86/.github/standards/CONVENTIONS.md`; each repo gets a synced copy at
`.standards/CONVENTIONS.md` that its `CLAUDE.md` imports. **Edit the source, never
the copies.** These rules apply to both the human and to Claude Code.

## Branching & PR ceremony

**The primary/default branch is `master`** (never `main`) in every repo,
including newly created ones. If a repo gets created with `main`, rename it to
`master` immediately (`gh api -X POST repos/<owner>/<repo>/branches/main/rename
-f new_name=master`) and point any submodule `branch =` refs at `master`.

**Branch → implement (+ tests) → version bump if user-facing → rebase → PR → CI green → squash merge → release**

1. Create a branch. Never commit on `master`, never push directly to `master`.
2. Implement the change with tests.
3. Bump the version if the change is user-facing (apps only — see Versioning).
4. `git fetch origin && git rebase origin/master`.
5. **Ask before opening the PR.** Then `gh pr create`.
6. Wait for CI to go green, then `gh pr merge --squash --delete-branch`.
7. If a version was bumped, cut the release (see Versioning).

**Squash-only merges.** `--merge` and `--rebase` are not used. On paid plans this
is enforced server-side by a ruleset; on free-tier private repos it can't be
enforced, so it is convention-enforced — follow it anyway.

## Versioning & release (apps)

- Bump `app/pyproject.toml`: **minor** = feature, **patch** = fix. Tooling, CI, or
  pure refactors get **no bump**.
- Cut production by publishing a GitHub Release: `gh release create vX.Y.Z`. That
  triggers the release workflow (test → build+push GHCR image + auth-service →
  deploy to the VPS).
- Rollback / redeploy an already-built tag:
  `gh workflow run release.yml -f image_tag=vX.Y.Z`.
- `deploy.sh` is an emergency rsync+build fallback only — never the normal path.

Infra (labs-infra) has **no version bumps or release tags**: modules deploy by
pulling latest `master` on the VPS.

## Testing

- **Apps: PostgreSQL only.** Every test path runs against `postgres:16`, the same
  backend as production. **Never use SQLite in app tests** — it hides prod-only
  write bugs (see LESSONS). The conftest asserts against SQLite.
- Postgres-safe patterns: `INSERT … RETURNING id` + `res.scalar_one()` (never
  `lastrowid`); fully qualify the column in revision-bump updates to avoid
  `AmbiguousColumnError`.
- CI gates every PR. For apps the gate is four jobs (test, lint/mypy, quality
  /coverage, e2e/Playwright); coverage has a `--cov-fail-under` floor.
- Run the suite locally before merging when Actions budget is exhausted (see
  LESSONS — budget resets monthly).

## Configuration & secrets

- **Config via env.** All required keys live in `.env.example`. `.env` and `data/`
  are git-ignored and Docker-ignored — never commit them or the database.
- **Never commit secrets.** OAuth credentials and keys live only in local `.env`,
  the VPS `.env`, and GitHub repo secrets. `.gitignore` covers `acme.json`,
  `.env`, `*.key`; the secret-hygiene tests assert none are tracked.
- **Self-contained images.** Fonts are bundled (woff2) — no CDN / Google Fonts
  calls at runtime. Keep it that way.
- Port mapping lives in `docker-compose.yml` (host → container); change the host
  (left) side only.

## Hub self-registration (new apps)

Every new Foundation-based app **self-registers with the wolf-labs hub**
(`dashboard-app`, `wolf-labs.de`) — the hub's product grid has no hardcoded app
list; it renders whatever has announced itself. Wire this in on day one, not as
an afterthought:

1. In `shell_config.py`, give `Brand(...)` its `accent`, `status`
   (`"live"`/`"beta"`), `description`, and `tags` — these render the app's
   product card on the hub.
2. In `module.py`'s `startup()`, call `foundation.registry.announce_once()` once
   and `start_heartbeat()` for periodic re-announcement (call
   `stop_heartbeat()` in `shutdown()`); build the manifest from `CONFIG.brand`
   plus the icon extracted from the app's own `_app_logo.html` (single source
   of truth — never duplicate the SVG). Gate all of it on
   `settings.registry_url`/`settings.registry_token` being set, so an app with
   neither configured is completely unaffected (no network calls, no
   behavior change) — this must stay true for local dev and CI.
3. Add `REGISTRY_URL`/`REGISTRY_TOKEN` to `.env.example` (unset by default).
4. Requires `foundation-api-engine >= v0.4.0` (ships `foundation.registry`) and
   `foundation-ui >= v0.6.0` (ships the `Brand` fields above).

See `beikost-app`, `packliste-app`, `scuba-app`, or `gs-app`'s `module.py` /
`shell_config.py` for the reference implementation, and `dashboard-app`'s
`app/routers/registry.py` for the hub-side endpoint contract.

## Code style

- All code, comments, and identifiers are **English**, even where UI content is
  German. Stored DB slugs (German) are keys and must never be renamed.
- Keep `CLAUDE.md` and these standards current when architecture or conventions
  change — update the source in `flowolf86/.github`, not the synced copy.
