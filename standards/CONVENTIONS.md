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

**Branch naming:** prefix branches with a type that describes the work, followed by a short slug:
- `feature/<slug>` — new functionality
- `bugfix/<slug>` — bug fix on a non-production branch
- `hotfix/<slug>` — urgent fix against a release/production branch
- `chore/<slug>` — tooling, CI, dependencies, no user-facing change
- `refactor/<slug>` — restructuring without behaviour change

Never use tool-name prefixes (e.g. `claude/`) — branch names describe the *work*, not the tool that created them.

**Branch → implement (+ tests) → version bump if user-facing → rebase → run tests locally (green) → PR → CI green → squash merge → release**

1. Create a branch. Never commit on `master`, never push directly to `master`.
2. Implement the change with tests.
3. Bump the version if the change is user-facing (apps only — see Versioning),
   and update `README.md` for anything the change touched (see Documentation
   — README correctness).
4. `git fetch origin && git rebase origin/master`.
5. **Run the full test suite locally and make it green BEFORE you push or open the
   PR — every single time, no exceptions.** CI is never your first test run.
   Pushing to a branch or opening a PR triggers CI, and CI is a shared,
   budget-capped resource (monthly Actions budget — see LESSONS). Burning CI
   minutes on a change you haven't run locally is wasteful and forbidden. If the
   local suite genuinely cannot run (e.g. no PostgreSQL / submodule available in
   the environment), run every check that *can* run locally, then say so
   explicitly in the PR and to the human before pushing — do not silently let CI
   be the first run.
6. **Ask before opening the PR.** Then `gh pr create` (only once local is green).
7. Wait for CI to go green, then `gh pr merge --squash --delete-branch`.
8. If a version was bumped, cut the release (see Versioning).

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
- **Every toggleable feature is tested in BOTH states — on AND off.** Any
  runtime flag, admin control, or feature switch must have tests proving the
  behaviour with the toggle *on* and with it *off* (and, where it matters, the
  default/unset state). A test that only exercises the "on" path lets the "off"
  path rot — a control that silently does nothing when disabled, or a feature
  that leaks when it should be dark, is exactly the bug the toggle exists to
  prevent. This applies to app-declared controls (hub control station), platform
  flags (maintenance, family switcher), and any per-app feature gate.
- **Always run the full test suite locally and get it green BEFORE pushing or
  opening a PR — every time, not just when the Actions budget is low.** Local-green
  is a *precondition* for triggering CI, never a fallback. CI is a shared,
  budget-capped resource (see LESSONS — budget resets monthly); using a push/PR as
  your first test run wastes it and can leave the team unable to merge for the rest
  of the month. Run `make test` / `pytest -q` (and lint/mypy) locally first; only
  push once it passes.
- If the environment cannot run the full suite (no PostgreSQL, missing submodule,
  etc.), run every check that *can* run locally and state clearly what was and was
  not verified — do not let CI be the first time the change is exercised.

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

## Third-party assets & attribution

Every self-hosted open-source asset gets credited — apps ship the assets in their
own image, so the attribution ships with them.

- **Every app has an `/licenses` page** (route + template, `noindex`), reachable
  from the drawer's legal section (`NavItem(section="legal")`) or, on the public
  hub, the footer. It credits the backend dependency stack (foundation engine +
  app extras), the bundled fonts (SIL OFL), and the icon set — one row each.
- **Bootstrap Icons (MIT) are used across the suite and MUST always be credited,
  even when the icons are copied into the app's own sprite** rather than pulled
  from the `bootstrap-icons` package. Copying the artwork does not remove the
  attribution obligation — the `/licenses` credit stays.
- **A copied third-party icon carries an inline comment naming its origin** at
  the sprite/symbol site (e.g. `{# trash3 — Bootstrap Icons (MIT) #}`), so the
  provenance travels with the markup and the next editor knows it is attributable.
  See `nebenkosten-app`'s `templates/base.html` sprite for the pattern.

## Hub self-registration (new apps)

Every new Foundation-based app **self-registers with the wolf-labs hub**
(`dashboard-app`, `wolf-labs.de`) — the hub's product grid has no hardcoded app
list; it renders whatever has announced itself. Wire this in on day one, not as
an afterthought:

1. In `shell_config.py`, give `Brand(...)` its `accent`, `status`
   (`"live"`/`"beta"`), `description`, and `tags` — these render the app's
   product card on the hub. **Provide bilingual card copy even for a
   German-only app:** the hub itself is multilingual, so the base
   `description`/`tags` (German default) must be paired with an English
   override via `i18n={"en": CardTranslation(description=..., tags=...)}`.
   Then send it: `module.py`'s manifest must include
   `"i18n": brand.hub_i18n()` (not just `description`) or the English card
   silently falls back to German on the hub.
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

## Working with Claude Code

These rules keep Claude Code productive across the repo family. They exist because
two failure modes kept recurring.

**Permissions — one wildcarded allowlist, not per-command grants.** Claude was
re-asking for rights already granted many times. The cause: allow-rules that pin an
exact command string (e.g. a full `curl … -d '{…}'`) only match that string, so any
argument change re-prompts; and the allowlist was app-specific and lived only in a
personal `settings.local.json`, so it never carried between repos. The fix is a
wildcarded, verb-level allowlist (`Bash(git push:*)`, `Bash(gh pr:*)`,
`Bash(docker compose:*)`, …) — canonical copy in
`flowolf86/.github/standards/claude-settings.json`, synced to `.standards/`. It is
installed globally in `~/.claude/settings.json` (covers every repo at once) and can
be union-merged into any repo's committed `.claude/settings.json`. Don't ask the
user to re-grant a verb the profile already covers — install/extend the profile.

**Don't declare defeat on the first failure.** Claude sometimes told the user "I
can't do X" after a single failed attempt, then did X fine when nudged — wasting
time and eroding trust. A permission granted earlier in a session persists; a rule
in `~/.claude/settings.json` persists across sessions. A non-zero exit or empty
result is usually a fixable problem (wrong dir, missing `git submodule update
--init`, unset env var), not a wall. **Rule:** read the actual error and retry the
real operation; prefer running the known-good path yourself over handing the user
commands to paste; only escalate when you've genuinely hit an auth/secret you don't
hold or a destructive action that warrants a confirm. State honestly what failed —
but exhaust the real attempts first.

## Documentation (README correctness)

Every repo's `README.md` is treated as **part of the change surface, not an
afterthought**. A README that lies — a stale version, a command that no longer
exists, a path that moved, an env var that was renamed, a feature that shipped or
was dropped — is worse than no README: it sends the next reader (human or Claude)
down a dead end and quietly erodes trust in all the docs.

**Rule:** before opening a PR, verify the README still matches reality for
anything the change touched, and fix it in the same PR. Concretely, a PR that
changes any of the following must update the README in lockstep:

- **Features / behaviour** — user-visible capabilities added, removed, or changed.
- **Setup or run commands** — install steps, `make` targets, dev-server command,
  ports, prerequisites (Python version, PostgreSQL, submodules).
- **Project structure** — top-level directories or entry points that the README's
  structure tree names.
- **Configuration** — env vars (added/renamed/removed), secrets, `.env.example`.
- **Deployment** — service name, DB name, image, or release flow.
- **Versioning** — a pinned version number the README asserts (prefer prose like
  "see `pyproject.toml`" over a hardcoded number that rots).

Correctness bar — every claim in a README must be checkable against the repo:
every command runs, every path exists, every env var is real, every version is
current. Don't guess or copy from a sibling app without verifying — the apps
differ. All wolf-labs READMEs follow one shared structure (title / tagline /
overview / family line → Features → Tech stack → Getting started → Testing →
Structure → Configuration → Deployment → Contributing → License); keep new/edited
READMEs in that shape so the family reads as one project.

This is enforced by convention and by the PR checklist item ("README verified
correct"), the same way squash-only and no-direct-push are. Reviewers (and the
PR author) tick it only after actually re-reading the affected README sections.

## Language (code and comments are English)

**All code and comments are written in English**, in every repo, even though the
product UI is German. This keeps the codebase readable to any contributor (human
or Claude), makes symbols greppable across the family, and stops German and English
identifiers from mixing inside one function. Concretely, English is required for:

- identifiers — variables, functions, classes, methods, modules, files, fixtures;
- comments and docstrings;
- commit messages, PR titles/bodies, branch names, and log messages;
- test names and assertion messages;
- documentation (`README.md`, `CLAUDE.md`, code-level docs).

**The narrow exception is highly specific wording that has no faithful English
equivalent** — keep the German term where translating it would lose meaning or
break a contract:

- **User-facing strings / i18n catalogues** — German UI copy is content, not code,
  and lives in the locale files (see `I18N.md`).
- **Stored DB slugs and enum keys** — German slugs are persisted keys; they are
  data, never renamed (a rename is a migration, not a translation).
- **Domain and legal terms of art** — e.g. `Nebenkosten`, `Grundsteuer`,
  `Impressum`, `Betriebskostenabrechnung`, `Hausgeld`. These are the real names of
  the concepts; keep them verbatim (optionally with a one-line English gloss in a
  comment on first use) rather than inventing an English approximation.
- **External API field names** — third-party payloads (e.g. BMW CarData) are used
  as given.

When in doubt, default to English; reach for the German term only when it is a
proper noun of the domain or a persisted key. New code follows this from the first
line; existing non-English code is converted opportunistically and tracked in
[`ROADMAP.md`](../ROADMAP.md).

## Code style

- Code and comments are **English** — see **Language** above; the only carve-outs
  are domain/legal terms of art, persisted DB slugs, and German UI strings.
- Keep `CLAUDE.md` and these standards current when architecture or conventions
  change — update the source in `flowolf86/.github`, not the synced copy.
- Keep `README.md` correct in the same PR as the change it describes — see
  **Documentation (README correctness)** above.
