# Lessons learned (the traps)

Hard-won gotchas that have bitten production. Source of truth:
`flowolf86/.github/standards/LESSONS.md`; synced into each repo at
`.standards/LESSONS.md`. **Append new traps here, once.** Each entry: the trap,
why it bites, and the rule.

## SQLite hides backend-specific bugs — apps test on PostgreSQL only

SQLite's permissiveness previously hid bugs (`RETURNING`, `ON CONFLICT`,
`lastrowid`) that broke every write in production. **Rule:** every app test path
runs against PostgreSQL — the same backend production uses. The conftest asserts
against SQLite so it can't sneak back in.

## The reverse proxy silently swallows `/api/auth/*`

The reverse proxy (Caddy on packliste, Traefik on beikost) routes `/api/auth/*`
to the Better Auth Node sidecar (port 3000). Any FastAPI route whose path starts
with `/api/auth/` is silently swallowed in production and never reaches Python —
it works locally without the proxy, then vanishes in prod. **Rule:** keep FastAPI
routes out of that prefix — e.g. `/api/profile`, not `/api/auth/update-user`.

## Never attach the immutable static cache to the catch-all route

The `/static` router uses an immutable 1-year cache — safe only because static
URLs carry `?v={{ revision }}`, which changes every deploy. The catch-all route
must use `no-store`. **Rule:** never attach `staticcache` to the catch-all — it
would cache dynamic HTML/API responses as immutable.

## Private foundation submodule needs an SSH deploy key in CI

The auto-provided `GITHUB_TOKEN` is scoped to the current repo and cannot clone
the private `foundation-api-engine` submodule. The `.gitmodules` URL is SSH
(`git@github.com:…`). **Rule:** CI fetches the submodule with the read-only
`FOUNDATION_DEPLOY_KEY` over SSH before any build/test step.

## Client JS is never exercised by pytest — `node --check` it in CI

pytest only drives the Python backend over HTTP; it never loads `app/static/*.js`.
A syntax error there (e.g. smart-quotes mangling `i18n.js`) ships green yet breaks
the whole UI. **Rule:** `node --check` every client script in CI before the build.

## E2E (Playwright) jobs must have timeouts — a hang burns the whole budget

A Playwright e2e test can hang indefinitely in CI (observed intermittently at
~74% through the larger packliste suite; **not reproducible locally** — the suite
passes in ~2.5 min — so it's CI-environment flakiness, not a code bug). Without a
guard the job runs until the runner limit, wasting the monthly Actions budget.
**Rule:** every e2e job sets `pytest --timeout=90 --timeout-method=thread`
(via `pytest-timeout`) so a hang fails in ~90s, plus `timeout-minutes` on the job
as a hard backstop. This lives in the reusable `app-ci.yml`.

## GitHub Actions budget resets monthly

When the monthly Actions budget is exhausted, CI won't run. **Rule:** run the
suite locally (`make test` / `pytest -q`), then merge the PR manually via the
GitHub UI. CI re-runs automatically once budget returns.

## Branch protection can't be enforced on free-tier private repos

GitHub Free gives private repos no rulesets or branch protection. Squash-only and
no-direct-push-to-master are therefore convention-enforced there, backed by the
client-side `pre-push` hook. On the paid plan the server-side ruleset enforces
them for real; keep the convention so a downgrade changes nothing.

## Local linter can revert the working tree

After commits, a local linter may reset working-tree files to the last committed
state. The remote branch always has the correct content. **Workaround:**
`git stash` before branch switches; verify with `git show origin/<branch>:<file>`.

## e2e: `wait_for_url("**/")` misses the post-create redirect

After creating an entity the server redirects to `/?<param>=<id>`, not bare `/`,
so `wait_for_url("**/")` hangs. **Rule:** assert on a visible element instead,
e.g. `expect(page.locator(".card").first).to_be_visible(timeout=8000)`.

## New repos default to read-only Actions permissions — breaks release.yml silently

A brand-new repo's Settings → Actions → General → Workflow permissions defaults
to "Read repository contents permission" (`default_workflow_permissions:
"read"`). `app-release.yml` declares `permissions: packages: write` (needed to
push images to GHCR) — on a "read" repo this makes the whole run fail with
`conclusion: startup_failure` and **zero jobs scheduled**, no annotation, no
check-run, nothing actionable in the UI. `ci.yml`'s call to `app-ci.yml` (only
needs `contents: read`) works fine on the same repo, which makes this look
like a bad workflow file rather than a permissions setting. **Rule:** when
bootstrapping a new app repo, set this immediately —
`gh api -X PUT repos/<owner>/<repo>/actions/permissions/workflow -f
default_workflow_permissions=write -F can_approve_pull_request_reviews=false`
— before wiring up `release.yml`, not after hitting the silent failure.

## VPS: redeploy config changes through release.yml, never raw `docker compose up -d` over SSH

Manually SSH'ing in and running `docker compose -f docker-compose.yml -f
docker-compose.prod.yml up -d` to pick up a `.env` change left two apps
(`packliste-app`, `gs-app`) crash-looping (exit code 3, dying right after the
Alembic "Will assume transactional DDL" log line, no traceback) — removing the
new env vars did not fix it, ruling out app code. Redeploying the identical
image/config through `gh workflow run release.yml -f image_tag=<current-tag>`
(clean `docker login` + `pull` + recreate via the CI runner) fixed both
immediately. Root cause was never pinned down, but the CI path is evidently
safer than ad-hoc SSH commands against shared Docker/containerd state on the
single multi-app VPS. **Rule:** to apply an env change to a running app,
`gh workflow run release.yml -f image_tag=<current-tag>` — never hand-run
`docker compose up` over SSH.

## Two private submodules need two deploy keys — a shared ssh-agent uses the wrong one

An app that vendors BOTH `foundation` (foundation-api-engine) AND `foundation-ui`
as private submodules needs a **separate read-only deploy key per repo** — a GitHub
deploy key is scoped to a single repo, so one key can never cover both. The obvious
"load both keys into `ssh-agent`" does NOT work: SSH offers keys until the server
accepts one, then GitHub scopes the whole authenticated connection to THAT key's
repo — so the second submodule clone fails with `ERROR: Repository not found` (a 404
masking a 403) even though both keys are valid and loaded. It looks like a missing
repo, not an auth-scoping problem, which sends you down the wrong path. **Rule:** give
each submodule its own SSH host alias pinned to its key with `IdentitiesOnly yes`, then
rewrite the submodule URLs to the aliases:

```
printf 'Host github-ui\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/id_foundation_ui\n  IdentitiesOnly yes\n' >> ~/.ssh/config
git config --global url."github-ui:flowolf86/foundation-ui".insteadOf "git@github.com:flowolf86/foundation-ui"
```

Each app mints its OWN read-only key on foundation-ui (`ssh-keygen` → `gh repo
deploy-key add <pub> -R flowolf86/foundation-ui -t "<app>-ci"` → store the private
half as the `FOUNDATION_UI_DEPLOY_KEY` secret; the private key never touches disk
afterward). The reusable `app-release.yml` already handles the second key via the
`github-ui` alias — a repo's own `ci.yml` must do the same, or its build job fails
while release still works, which is baffling until you know this.

## A documented lesson only helps if the repo is wired to surface it

`standards/LESSONS.md` is worthless to a repo that doesn't import it. Every app repo needs
THREE things or the lessons reach nobody: (1) a top-level `CLAUDE.md` that `@.standards/CONVENTIONS.md`
and `@.standards/LESSONS.md`, (2) the `.standards/` copies, and (3) the `sync-standards.yml`
workflow that keeps them current. An app built by hand instead of cloned from an existing app
gets NONE of this — the lessons are nowhere in its working surface, so the human and Claude both
re-hit every documented trap from scratch. This is not hypothetical: `nebenkosten-app` shipped
its first release having re-encountered the read-only-Actions-permissions trap AND the
foundation deploy-key trap — both already in this file — purely because it had no top-level
`CLAUDE.md`, no `.standards/`, and no sync workflow. The knowledge existed; the delivery didn't.
**Rule:** step ONE of bootstrapping a new app repo is wiring standards delivery — copy an
existing app's `CLAUDE.md` (keep the `@.standards/*` import lines), add `sync-standards.yml`,
run it once, and confirm the import resolves — before any app code. CI check to make it
impossible to forget: `grep -q '@.standards/LESSONS.md' CLAUDE.md && test -f .standards/LESSONS.md`.

## The Impressum must be reachable WITHOUT login — a gated Impressum fails its only job

§ 5 TMG/DDG requires the Impressum for *anonymous* visitors — the public, competitors,
regulators. The foundation app pattern routed `/impressum` through `CurrentUser`, so the
one audience that legally matters could never see it, and the login card (the only page
an anonymous visitor reaches) had no Impressum link at all. Found in nebenkosten-app's
UX audit; every app built from the same pattern likely shares the gap. **Rule:** the
`/impressum` route takes NO auth dependency (resolve the user best-effort for the shell,
tolerate `actor=None` — the shell's `actor is defined and actor` guards handle it), and
the login card carries a small Impressum footer link. Regression test: GET `/impressum`
returns 200 with all credential resolution forced to 401. When porting, note the FastAPI
trap that a zero-arg dependency override is required — a `*args` signature is misread as
request parameters and yields a 422.

## Playwright `color_scheme="dark"` proves nothing for attribute-based theming

The shell applies dark mode via `html[data-theme="dark"]` (user setting), not
`@media (prefers-color-scheme)`. Emulating the OS preference with Playwright's
`color_scheme="dark"` therefore renders the LIGHT theme — a whole "dark-mode audit"
screenshot set was silently identical to the light set and gave false confidence.
(The same emulation gap also masked the real product bug: theme "System" never resolved
the OS preference — fixed in foundation-ui #72 by resolving auto via `matchMedia` and
setting `data-theme` explicitly.) **Rule:** to capture dark mode, set the app's real
mechanism (`localStorage.theme = "dark"` or stamp `data-theme` before capture), and
sanity-check that dark captures actually differ from light (byte/hash compare) before
auditing them.

## Async submit handlers without an in-flight lock create duplicate writes

Every `submit → preventDefault → await POST → location.reload()` handler leaves the
submit button enabled during the await: a double-click or double-Enter (typical for
senior users) posts twice and creates duplicate records before the reload lands. In
nebenkosten-app 21 of 25 forms had this hole. **Rule:** wire async form submits through
a shared guard that disables the submit buttons on entry and re-enables in `finally`
(`NBK.guardSubmit(form, handler)` in nebenkosten-app — copy the pattern), and the same
for async click handlers on destructive/creating buttons. While there: don't
`toast(...); location.reload()` in the same tick — the reload destroys the toast; delay
the reload (`toastThenReload`) so success feedback is actually seen.

## Parallel pytest runs against the one shared test Postgres produce phantom failures

Multiple agents/processes running the app test suite concurrently against the single
`nbk-test-pg` collide on TRUNCATE-based cleanup: tests fail with confusing
"Eintrag nicht gefunden"/deadlock flavors that look like real regressions, failure
counts vary per run, and every failing test passes in isolation. This burned significant
diagnosis time during a multi-agent implementation session. **Rule:** treat the shared
test DB as a serial resource — one suite run at a time; for parallel agent workflows,
either stagger test runs or give each worker its own database (CREATE DATABASE per
worker). Before chasing a "regression" seen only in a parallel run, re-run the full
suite serially once.

## The VPS deploy runs one big SSH command in double quotes — inner strings must be single-quoted

`app-release.yml`'s "Pull image and restart the stack" step wraps the entire remote
command in ONE double-quoted argument to `ssh` (`ssh root@host "( flock … ) 9>…"`).
Every string inside that argument must therefore use **single** quotes. A stray inner
`echo "…"` (introduced by the "make image prune non-fatal" change) closed the outer
double-quote early, so the runner's *local* bash — not the VPS — then parsed the
leftover `(daemon busy; …)` and died with `syntax error near unexpected token '('`.
The build/push jobs are green, only Deploy fails, and the traceback points at a runner
temp script, so it reads like a runner glitch rather than a quoting bug in the YAML.
It shipped to `dot-github` master and broke the very next app release (nebenkosten
v0.22.0). **Rule:** inside that `ssh "…"` block use single quotes for every echo/string,
and byte-check the assembled command with `bash -n` (GHA expressions stubbed) before
merging any edit to that step.
