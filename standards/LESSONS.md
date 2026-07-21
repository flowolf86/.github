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

The reverse proxy (Traefik on every app — packliste's own
`docker-compose.prod.yml` uses Traefik labels + the `letsencrypt` resolver, not
Caddy as earlier notes claimed) routes `/api/auth/*`
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

It can go further than the working tree: observed in dashboard-app doing a *soft*
`git reset` that moved local `HEAD` back one commit and re-staged the just-committed
changes, so `git rev-parse HEAD` no longer matched `origin/<branch>` even though the
push had succeeded and the PR was correct. This reads like the commit vanished. Don't
re-commit or panic — the pushed commit is intact. **Rule:** after a push, if local
state looks scrambled, trust the remote: verify the branch with
`git show origin/<branch>:<file>` / `gh pr diff`, then realign local with
`git reset --hard origin/<branch>` rather than reconstructing the change.

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

## Tests anchored to the wall-clock date rot silently

Tests that hardcode dates near "today" (a due date, a billing period, an intake
week, a maintenance interval) pass when written and start failing weeks later as
real time drifts past the baked-in assumption — a green suite that quietly turns
red on a calendar boundary, not a code change. It bites every app with
time-relative logic (beikost intake weeks, scuba dive dates, gs service
intervals, nebenkosten billing periods). **Rule:** anchor time-based test data to
`date.today()`/`datetime.now()` (offset from it), never to literals; check BOTH
`app/tests` (unit) and `app/e2e` — they rot independently — and prove it by
freezing "today" on both sides so a future date can't change the outcome.

## StaticFiles 404s on symlinks that escape the mounted directory

Serving the shared foundation-ui shell bundle by symlinking it into the app's
static mount works in some setups but 404s under uvicorn/Starlette `StaticFiles`
when the symlink target resolves *outside* the mounted directory — the resolved
path fails the "is this within the mount root" containment check, so the asset
vanishes only in the real server (and e2e), not in whatever dev shortcut was used.
**Rule:** don't symlink cross-package static into the mount — **copy** the shell
bundle into the served directory (a build/Docker step), and treat the copied files
as build output, not source.

## Concurrent VPS deploys collide on the shared docker prune, not the deploy

All apps deploy to one VPS. Releasing several at once serialises the deploy itself
via the host `flock`, but `docker image prune` holds its own global daemon lock
that lingers briefly after the flock releases, so a second deploy's prune can fail
even though its deploy succeeded. The release looks failed when only cleanup was
skipped. **Rule:** keep the prune step non-fatal (`|| echo skipped`) — stale
images get cleaned on the next deploy; re-run the (idempotent) deploy or stagger
releases rather than chasing a "failed" deploy that actually shipped.

## Changing a CSS variable's VALUE does nothing if no rule consumes it

dashboard-app shipped a "new body typeface" (Hanken Grotesque) that looked
byte-identical before and after — because the change only reassigned the `--body`
custom property on `body.hub`, and *nothing* applied `font-family: var(--body)` to
the body element. The hub replaces the shell chrome wholesale, and the shell only
consumes `--body` on its own components, so the hub's running text inherited no
font-family and silently fell back to the UA default serif. The @font-face even
loaded fine (200, `font/woff2`) — a loaded font and a defined token both looked
like success while the text rendered in Times. A token swap is not a visible change:
it needs a *consumer*. **Rule:** when a design-token change is supposed to alter the
UI, verify the **rendered result** (screenshot / `getComputedStyle`), not that you
edited the token — and confirm some rule actually reads the token on the element you
care about. Tell: a font stack ending in `sans-serif` that renders as serif means
`font-family` is unset on that element, not that the webfont failed (a set stack
would fall back to sans, never Times). Sibling of the `color_scheme="dark"` proves-
nothing trap: assert the real mechanism, not a proxy.

## Prior Docker builds leave root-owned artifacts that block local editable installs

An app that vendors `foundation`/`foundation-ui` as submodules and has been built
with Docker at some point can carry root-owned `build/` and `*.egg-info/` directories
inside those submodules (Docker's build user wrote them). A later `uv pip install -e`
/ `pip install -e` then fails with the cryptic `error: Cannot update time stamp of
directory '<pkg>.egg-info'` — setuptools can't rewrite the root-owned egg-info, and
the message names a timestamp, not a permission, so it reads like a tooling bug. It
blocks every local test run (no editable install → `ModuleNotFoundError: foundation`),
which is why the suite silently becomes "CI-only". **Rule:** if an editable install
fails on egg-info/build timestamps, check ownership (`ls -ld packages/*/build
packages/*/*.egg-info`); clear the stale root-owned artifacts (`sudo rm -rf` — they're
regenerated build output, never source) before diagnosing further. Passwordless sudo
usually isn't available to the agent, so hand the one-liner to the human once and
verify it took.

## After every task, capture the lesson — auto-PR-and-merge it, don't ask

Lessons are worthless if they're never written down, and asking "shall I record
this?" after every task adds friction that means they mostly aren't. **Rule (standing
authorization):** at the end of every task, evaluate whether a genuinely reusable
trap/insight emerged (something non-obvious that cost time or would bite again). If
so, add it to the canonical `flowolf86/.github/standards/LESSONS.md` — **the source,
never a repo's `.standards/` copy** — as one tight entry (trap / why it bites / rule),
then open the PR **and squash-merge it automatically**, without pausing to ask. This
is an explicit override of the usual "ask before opening the PR" ceremony, scoped to
lessons-learned updates only. Skip when nothing rises above the bar (don't manufacture
filler) or when it duplicates an existing entry (augment that one instead). Keep it
one-entry-per-trap and quality-gated — the value is in the signal, not the volume.

## A fixed bug becomes a *standing artifact* — classify it, don't default to prose

A prose lesson helps a human re-reading it; it does nothing at runtime. The diagnostics
substrate (`foundation.diagnostics` — probes at `/_diag/selfcheck`, explainers at
`/_diag/explain`, fleet board on the hub) exists so that a fixed bug can become an
*executable* guard, not just a paragraph. **Rule (extends the capture-the-lesson step
above):** at the end of a fix, classify it into the right standing artifact instead of
reflexively writing prose:

| Classify as | When | Artifact |
|---|---|---|
| **test** | preventable pre-merge; deterministic | a unit/integration/e2e regression test |
| **probe** | a *class* of bug, cheaply + safely expressible as a live read-only invariant, that recurs in prod | a `ProbeSpec` registered in a provider (`foundation/diagnostics/providers/` or an app domain provider) |
| **explainer** | the slow part was "why is *this* request/entity in this state" | an `Explanation` contributor |
| **lesson-only** | one-off / not runtime-expressible (a typo, a process slip, a mis-merge) | a prose entry here, as today |
| **both** | prevent *and* diagnose-fast (e.g. the get-session rate-limit logout) | a test **and** a probe |

Guardrails — the same bar as a LESSONS entry, don't manufacture filler:
1. **Gate:** add a probe/explainer only if it's a *class* of bug, cheaply and safely
   expressible (read-only, fast, verdict-only — never rendering rows/emails/tokens), and
   would have shortened the diagnosis. Otherwise it stays a prose lesson.
2. **Verify-it-fires:** a new probe must be proven to go **red on the pre-fix state**
   (synthetic repro) and green after — a probe that can't detect its own bug is theatre.
   `foundation.testing.probe_gate.make_probe_gate` collects the healthy-green side; the
   red-on-broken-state assertion lives in the provider's own test (see
   `test_diagnostics.py::test_disabled_column_probe_fires_when_column_dropped`).
3. **Retirement + cost budget:** probes are read-only, fast, owned. A **flapping probe
   erodes trust faster than no probe** — retire stale/flaky ones, don't tolerate them.
4. **Traceability:** every probe/explainer carries `ref=` back to the lesson slug /
   incident PR, so the fleet board can attribute a red probe to its origin. Over time the
   probe library *is* the incident history, executable.

Where the artifacts live: **engine-wide** invariants (auth/schema/config/version) →
`foundation/diagnostics/providers/`; **app-specific** invariants (billing periods,
sharing/family, shell token-remap) → an app-owned domain provider registered in the app's
`module.py` startup, announced to the hub on the existing heartbeat
(`manifest["diagnostics"] = probe_summary(await run_probes())` + the failing-probe list,
gated on `registry_url`/`registry_token` like `stats`).

## The GitHub file-write API silently rewrites U+201D to ASCII quote -- keep pushed code pure-ASCII

Writing a file through the GitHub content API (the `create_or_update_file` MCP tool, and the web
editor's paste path) silently rewrites the typographic RIGHT DOUBLE QUOTATION MARK (U+201D) to an
ASCII double quote on the round-trip. In prose that is invisible; in a JS/JSON/Python string it is
catastrophic -- the ASCII quote terminates the string early, so a locale catalogue that parsed and
ran locally ships a `SyntaxError` that breaks the whole UI. It cost a full debugging loop on
nebenkosten-app's `locales.js` (a German closing quote right after an interpolation placeholder),
and it is invisible in the PR diff because the two glyphs look identical. **Rule:** never put a
literal delimiter-confusable smart quote (U+2018/2019/201C/201D/201E) in source pushed through the
API -- write it as a `\uXXXX` escape (identical at runtime, pure ASCII on the wire). This is the
machine-checked half of the i18n standard (`standards/I18N.md`), enforced suite-wide by the locale
gate (`foundation.testing.locale_gate`). For any file pushed via the API, prefer pure-ASCII source;
after pushing a file that must carry non-ASCII, fetch it back and byte-compare before trusting it.

## foundation-ui's gate audit JS isn't in package-data — a non-editable install drops it

`foundation-ui` ships the CI gate audit scripts at `foundation_ui/testing/*_audit.js`
(geometry/motion/field/contrast/focus), but its `[tool.setuptools.package-data]` only globs
`templates/…` and `static/shell/…` — the `testing/*.js` files are **not declared**. A
**non-editable** `pip install ./packages/foundation-ui` (or a wheel) therefore silently omits
them, and an app's Playwright/gate suite then fails at *collection* with
`FileNotFoundError: …/foundation_ui/testing/<x>_audit.js` — which reads like a broken test,
not a packaging gap. It bit all five apps during the foundation v0.10.0 pin rollout. The reusable
`app-ci.yml` installs foundation-ui **editable** (`pip install -e packages/foundation-ui`), so the
resource resolves from the source tree and CI is green — which masks the gap until someone runs a
non-editable local install (the natural choice for a "clean copy" test harness). **Rule:** install
`foundation-ui` **editable** (`-e`) anywhere you run an app's e2e/gate suite locally, mirroring CI;
and the real fix is to add `"testing/*.js"` (and any other runtime-loaded non-Python assets under
`foundation_ui/`) to foundation-ui's `package-data` so a wheel/non-editable install is self-contained.

## A whole-site 503 is usually the engine's maintenance gate, not a Traefik/infra outage

An app returning `503` on every page — but the container still healthy — is almost always the
Foundation engine's own **maintenance gate**, not a reverse-proxy or infra failure. The gate
(`foundation/app_factory.py`, `_register_maintenance_gate`) serves a 503 "Wartungsmodus" HTML page
for *every* route except `/healthz` and `/api/auth` whenever the hub has flagged the app
(per-app Wartungsmodus, or a central lockdown) — the flag lives in the registry and is refreshed
on each announce. This is a deliberate, hub-toggled state, not a crash. Its tells are unambiguous:
`GET /` → `503` with `<title>Wartungsmodus</title>`, `Retry-After: 120`, `Server: uvicorn`, while
`GET /healthz` → `200` (the gate exempts it, so Docker/Traefik still see the backend as healthy).
The trap: this looks identical to a Traefik "no healthy backend" 503, so it lures you into a deep
infra rabbit hole — crowdsec middleware, router/middleware names, docker network IPs, ACME certs —
chasing an outage that doesn't exist. This cost significant time on gs/scuba: multiple wrong
theories (crash-loop, middleware-name collision, crowdsec double-apply) before anyone read the 503
*body*, which said "Wartungsmodus" in the first line. A change was even shipped and reverted on the
false diagnosis. **Rule:** when a wolf-labs app serves a site-wide 503, FIRST `curl -sS https://<host>/`
and read the body — a `Wartungsmodus` page (and `/healthz` → 200) means maintenance/lockdown is
toggled ON in the hub admin (Kontrollzentrum), so the fix is to toggle it *off there*, nothing to
debug. Only once you've confirmed the body is NOT the maintenance page (and `/healthz` is failing
or timing out) should you investigate Traefik, crowdsec, certs, or the container itself.

## Run the app suite from `app/` — a repo-root pytest run loads the PRODUCTION `.env`

`foundation.config.Settings` sets `env_file=".env"`, which pydantic-settings resolves
**relative to the current working directory** — not to the config module. Every app repo keeps
its real `.env` at the root (gitignored, full of production values), so running `pytest` from
the repo root silently loads it: `PUBLIC_BASE_URL=https://www.<app>.de` then makes the admin
CSRF origin check reject the tests' `http://localhost:8086` origin, and **~19 admin/registry
tests fail with `403`/`assert 0 == 1`**. Nothing names `.env` in the output — the failures read
as real regressions in admin auth, which is a long way from "wrong directory". CI never sees
this because it runs from `app/`, where no `.env` exists and the defaults are the test values.

A root `pytest.ini` compounds it: pytest picks ONE config file, so a root `pytest.ini` shadows
`app/pyproject.toml` and its `foundation_test_dsn` is never read — the shared harness
(`foundation.testing.pytest_plugin`) then goes inert, never forces `DATABASE_URL`, and every
test errors with a `Settings` `database_url ... Field required` **validation** error that looks
like a broken install rather than a missing ini. (Same family as the editable-install trap
above: an agent without a venv hits both back to back and concludes the suite is CI-only.)

**Rule:** run the **unit** suite from the app directory (`cd app && pytest -q`), never from the
repo root. (The **e2e** suite is the exception and runs from the root against `pytest-e2e.ini` —
its conftest hard-sets `PUBLIC_BASE_URL`/`ADMIN_EMAIL`/`SESSION_SECRET` as real env vars, which
outrank any `.env`, so it is immune. Don't "fix" it by moving it into `app/`.)
If admin/registry tests 403 while the rest pass, check `pwd` before you debug auth — and
confirm with `python -c "from foundation.config import get_settings; print(get_settings().public_base_url)"`,
which prints the production URL when you've picked up the wrong `.env`. When installing without
Docker, note the harness auto-loads via a `pytest11` **entry point**: a `PYTHONPATH`-only setup
has no dist-info, so the plugin never loads — add `-p foundation.testing.pytest_plugin`.

## A handed-over animated SVG can arrive with its `<style>` stripped — and a hidden base state ships it blank

Design pipelines commonly sanitize `.svg` on write and drop `<style>`/`<animate>`. The
nebenkosten mark arrived that way **twice**: v1 kept its inline `stroke-dasharray`/
`-dashoffset` but lost the `@keyframes` that would have animated the offset back to 0 — so
every path sat at full offset and the icon rendered **invisible**; v2 replaced the dash
attributes with `--l` custom properties that no surviving rule consumed, so it rendered
**fully drawn but frozen**, byte-identical to the static file. Both *look* fine in a diff —
the paths, the delays and the lengths are all present and correct. Design eventually shipped
the deliverable as `nebenkosten-motion.html` (the `<svg>` inside it copied verbatim to `.svg`
animates identically) precisely because their pipeline could not emit a working `.svg`.

Two rules, and the second is the one that saves you:

**Verify on arrival, in an engine.** `document.getAnimations().length` (expect > 0),
`getComputedStyle(path).strokeDasharray` (expect a length, not `none`), and frames sampled
across the timeline (expect them to differ). Reading the file proves nothing — a stripped
`<style>` leaves valid, plausible markup.

**Keep the hidden state OUT of the base rule** — this is what makes a stripped `<style>` a
non-event instead of an invisible logo:

```css
/* fail-safe: base state IS the drawn mark; hidden state exists only while animating */
.nk-draw { animation: nk-draw .34s cubic-bezier(.65,0,.35,1) both; }
@keyframes nk-draw {
  from { stroke-dasharray: var(--l) var(--l); stroke-dashoffset: var(--l); }
  to   { stroke-dasharray: var(--l) var(--l); stroke-dashoffset: 0; }
}
```

`animation-fill-mode: both` back-fills the `from` state during each path's `animation-delay`,
so the draw-in still works — but if the animation never runs (stripped style, blocked CSS,
reduced motion, an engine quirk) the element simply renders drawn. Putting
`visibility:hidden` or the dash props on the element itself re-creates the exact bug. Same
family as *"Changing a CSS variable's VALUE does nothing if no rule consumes it"* — `--l`
without a consumer is inert.

**Corollary — pixel proxies lie when verifying this.** Element screenshots composite whatever
paints *behind* the element (a card/tile background makes every capture 100% opaque, so
"ink coverage" reads identical in every state); serializing the node to a `data:` URL drops
the external stylesheet, so it always renders the *base* state and reports success no matter
what; and a demo page's own CSS (`.tile svg{width:120px}`) outranks a `width` attribute you
set. Four separate "it differs!" results in a row were all measurement artifacts, not the
animation. Assert the animated **property** via `getComputedStyle`/`getAnimations` and seek
the timeline with the Web Animations API (`anim.currentTime = t`) rather than racing the wall
clock; only compare pixels after normalising size, background and layout.

## The hub icon extractor regex-matches tag literals in the template's comment prose

Every foundation app announces its product card with `module.py::_icon_inner_svg()`, which
regex-matches `<svg[^>]*>(.*)</svg>` over the **raw** `_app_logo.html` and ships the inner
markup. Documenting the mark with a comment that mentions a tag literally — e.g. *"the euro's
stroke sits on the `<g>`, not the root `<svg>`"* — makes that prose `<svg>` the first match, so
the hub receives the tail of your comment plus a nested root element instead of clean paths.
The app itself renders fine (Jinja strips the comment at render time); only the hub card
breaks, in a different repo, with no error anywhere. **Rule:** strip Jinja comments before
matching (`re.sub(r"\{#.*?#\}", "", src, flags=re.DOTALL)`), keep tag literals out of that
comment, and assert the extracted payload in a test — non-empty, no `<svg`, no `{#`/`{%`, and
parses standalone once re-wrapped. While there: the hub re-wraps the inner markup in its own
`svg` at `stroke-width: 2`, so any stroke weight that differs from the house's (a lighter euro,
a hairline detail) must live on an inner `<g>` — a root-level attribute is silently discarded.

## A bottom-bar app must not also set `nav_rail=True` without the shell knowing

The foundation-ui shell has TWO desktop-rail mechanisms and they collide. `primary_nav="bottom-bar"`
gives `body.has-rail`, which at ≥600px transforms the bottom bar into a left rail — automatic, no
opt-in. `nav_rail=True` gives `body.nav-rail`, a SECOND, standalone `.shell-rail` element at ≥768px.
Set both (a bottom-bar app that also opts into `nav_rail` for "packliste parity") and the two navs
stack on the left — and the standalone rail is near-empty because `drawer_main()` returned `[]` for
bottom-bar apps, so it renders brand + settings only. It looks like "the rail won't disappear."
packliste is fine because it's `primary_nav="drawer"` — only `nav-rail`, never `has-rail`, and its
`drawer_main()` is populated. **Rule:** "parity" is per-nav-mode, not per-flag. A bottom-bar app that
wants the rich `.shell-rail` needs the shell to (a) scope the `has-rail` bottom-nav transform to
`:not(.nav-rail)`, (b) hide the bottom bar where the rich rail shows, (c) keep the hamburger so the
drawer's settings/legal stay reachable (only drawer-primary rail apps hide it), and (d) have
`drawer_main()` return the primaries so both the rail and the drawer's first section are populated.
Don't just flip `nav_rail=True` on a bottom-bar app and assume packliste's outcome.

## A held identity-value transform (`scale(1)`, `rotate(360deg)`) still composites — end at `none`

A one-shot CSS entrance animation with `animation-fill-mode: both` HOLDS its 100% keyframe. If that
keyframe is `transform: scale(1)` / `rotate(360deg)` / `translateY(0)` — an identity *value* but still
a transform — the browser can keep the element on its own composited layer and render it softly
(blurry) forever after the motion ends, even though the JS "settle" that drops the animation should
release it. The fix is to end the keyframe at `transform: none` (no transform at all), which releases
the layer so the element re-rasterizes sharp at device DPI. This bit the foundation-ui nav-icon
entrances: only `nav-book` (deliberately ending at `none` for a 3D case) stayed crisp; the 2D ones
held `scale(1)`/`rotate(360deg)` and stayed soft. **Rule:** any `fill: both`/`forwards` entrance that
should look untouched at rest must end its final keyframe at `transform: none`, never an identity-valued
transform — and don't rely on a JS settle hook alone to undo the composite.

## The shell's `data-en` swap caches German on first use — never point it at reused elements

foundation-ui's bilingual swap freezes the German copy into the DOM the first time it
runs: `if (!("de" in el.dataset)) el.dataset.de = el.textContent` (`shell/i18n.js`).
That is correct for static page text, whose German never changes — but it makes
`data-en` **wrong for any element whose content is rewritten at runtime**. A single
reused node (one label chip serving nine hero planets, a toast, a modal title) gets
`data-de` stamped with whichever app's German happened to be showing at the first
switch; from then on every DE→EN→DE round-trip restores *that* name, not the current
one. It fails only on the second language switch, so it survives every first-load
check, and the element still switches languages — just to stale content — which reads
like a data bug rather than a caching one. **Rule:** `data-en` is for server-rendered
text that stays put. For anything re-rendered by JS, carry both languages on the
*source* (`data-name`, `data-status-de`/`-en`) and have the renderer pick by
`document.documentElement.lang`, re-rendering on language change. Prove it with
`window.setLang("en")` → `setLang("de")` on a node that has displayed two different
values, and assert the accessible name too — an `aria-label` built the same way goes
stale identically and no screenshot will show it.

## A CSS animation overrides inline styles — even while paused — so scripted sweeps measure nothing

To find out whether dashboard-app's hero label clipped at the frame, the obvious probe is
to walk the orbit by hand: `arm.style.transform = 'rotate(Xdeg)'`, sample, repeat. It
reports plausible numbers and they are **fiction** — animated properties sit above inline
styles in the cascade, so a `transform` under an `animation` is simply ignored and every
sample comes from the one angle the animation happens to be at. `animation-play-state:
paused` does NOT help: a paused animation still applies its current value, which is
exactly the state a "let me freeze it and measure" instinct puts it in. The tell is subtle
because per-element results still *differ* (each element sits at its own angle), so the
output looks like a real sweep. It under-reported dashboard-app's clipping as "narrow
viewports only, ~30px"; the truth was every viewport, up to 82px, on every planet.
**Rule:** to script an element through an animated range, kill the animation first
(`el.style.animation = 'none'`), then set the property — and make the probe prove it moved
(assert the sampled positions actually vary, or count distinct values) before trusting a
single number it prints. Sibling of the `color_scheme="dark"` and token-swap traps: assert
the real mechanism, never a proxy for it.

## `pytest app/e2e` from the repo root loads the WRONG config and silently kills the server thread

The app suites live in `app/tests` (run from `app/`) and `app/e2e` (run from the root), and
pytest picks its config from the *arguments*, not the cwd: `pytest app/e2e` walks up from
`app/e2e`, finds `app/pyproject.toml` first, and adopts rootdir=`app/` — including its
`filterwarnings = ["error"]`. That turns uvicorn's websockets `DeprecationWarning` into a
fatal exception **inside the daemon thread** running the e2e server. Every test then fails
identically with `RuntimeError: E2E server at http://localhost:8091/healthz did not start
within 15.0s`, and the real exception is swallowed by the thread. The traceback points at
the fixture, so it reads like a port clash, an unreachable database or a broken conftest —
and the server boots perfectly when you run it by hand, which sends you hunting further.
The root `pytest.ini` (no `filterwarnings`) is the config CI actually uses. **Rule:** run
e2e as `pytest -c pytest.ini app/e2e` to pin the root config. When an e2e fixture reports
"server did not start" but a manual boot works, suspect config/warning-filter scope before
the server: re-run the fixture's own construction in-process and print the thread's
exception rather than believing the timeout.

## A service that boots is not a service that works — provisioning belongs in code, not a README

The Better Auth `auth-service` ran in production for its entire life, in all six
apps, with **no database schema at all**. Applying `sql/better_auth_schema.sql` was
step 1 of the service's README (`npm run migrate:schema`) and **nothing ran it** —
not the Dockerfile's CMD, not `app-release.yml`. Three things then conspired to hide
it completely: the container started fine and logged `listening on :3000`; `/healthz`
returned `{status:"ok"}` **without ever touching the database**; and CI was green
because pytest never drives the Node sidecar (`server.ts`/`auth.ts` were even excluded
from coverage as composition roots "exercised by the deferred cross-stack E2E" — an
E2E that never arrived). Every `/api/auth/*` request 500'd on `relation "rateLimit"
does not exist`, but the only user-visible symptom was email/password login failing —
and since every login in the family actually goes through a *different* (legacy Python
OAuth) path, nobody ever hit it. The DDL was also wrong in a second way that only a
real request could reveal: `jwks` existed but lacked its `expiresAt` column, and a
table that exists but is shaped wrong fails exactly like an absent one (`CREATE TABLE
IF NOT EXISTS` will never repair it — you need an explicit `ALTER ... ADD COLUMN IF
NOT EXISTS`). **Rules:** (1) provisioning/migration runs from code on every boot
(idempotent DDL), never from a documented command — a deploy step that lives only in
prose is not a deploy step; (2) verify after provisioning and **refuse to listen** if
the schema is incomplete — a crash-loop and a red deploy are loud, serving 500s is
silent; (3) derive "what must exist" from the library's own schema (e.g. Better Auth's
`getAuthTables(auth.options)`) rather than a hand-written list — the missing table only
existed because `rateLimit.storage="database"`, and hand-lists are how DDL and config
drift apart; (4) a health check that does not touch the dependency the service exists
to use is theatre — probe the real pool; (5) if a component is excluded from coverage
"pending an E2E", assume the E2E will never be written and that this is exactly where
the bug will live: one test that applies the schema and sends a real request would have
caught all of it on day one.

## Dependency/attribution tests assert the canonical dist name, not the branded name

The compliant `/licenses` page (and any test over installed-metadata output) lists
each component under its **canonical PyPI distribution name** as `importlib.metadata`
reports it — `fastapi`, `pydantic-settings`, `typing_extensions` — *not* the marketing
capitalisation (`FastAPI`). dashboard-app's licenses test asserted `"FastAPI" in
page.text`; it failed while the page was fully correct, and because the failing string
was absent the rendered HTML *looked* empty of content — sending diagnosis down an
"empty-render / template-not-rendering" rabbit hole when the only bug was the assertion's
casing. A green page plus a failing substring assertion reads like the page rendered
nothing; it usually means the substring is wrong, not the page. **Rule:** in tests over
dependency/attribution listings, assert the lowercase canonical distribution name (match
what `importlib.metadata.distributions()` yields), consistent across the app family; and
when a "page renders empty" symptom appears, probe the actual `page.text` for known-good
markers (a heading, a panel class) before assuming the template failed.

## A per-app pinned "moving" tag drifts silently — one app in a family gets left behind

Rolling a foundation/auth-service fix across all six apps: five picked it up, one (gs)
silently did not. Cause: the app image deploys on a pinned release tag
(`IMAGE_TAG=vX.Y.Z`), but the **auth-service** sidecar uses a *moving* tag,
`image: .../auth-service:${AUTH_SERVICE_TAG:-latest}`. Five apps left it unset (→
`latest`); gs's VPS `.env` pinned `AUTH_SERVICE_TAG=v1.0.0`. So gs's deploy did
`docker compose pull` on `v1.0.0` (unchanged, months old) and `up -d` saw no diff and
**did not recreate the container** — the sidecar sat at an ancient image while its
release went green, because the release only builds/pushes and the deploy "succeeded"
at pulling an image that simply hadn't changed. The tell was not in any log: the
container's `Up 11 days` while its siblings read `Up 2 minutes`. **Rules:** (1) across a
repo family, a moving-tag reference (`:latest`, `:stable`) must be set the SAME way
everywhere — audit it explicitly (`grep AUTH_SERVICE_TAG /opt/*/.env`), because one
app pinned to an old value is invisible until you compare running-image age; (2) after
a fleet rollout, verify the *running image/uptime* of the thing you changed, not just
that each release went green — a green deploy that pulled an unchanged pinned tag is a
no-op that looks identical to success; (3) a stale pin can only be repaired by changing
the pin (a VPS `.env` edit) and redeploying — a plain redeploy re-pulls the same stale
tag. And note the recovery wrinkle: a `workflow_dispatch` deploy-only path pulls the
existing image and cannot fix a `:latest` whose registry manifest has gone bad
(`NotFound: content digest … not found`, seen after concurrent deploys' `docker image
prune`); only a full release *rerun* that rebuilds and repushes the image restores it.

## Bearer-only auth silently excludes server-rendered page navigations

The Foundation auth dependency advertised its "primary production path" as an
`Authorization: Bearer <jwt>` header verified against JWKS. That is correct for
client-side XHR/fetch (`api.js` sets the header) — but a **top-level browser
navigation carries no Authorization header**, only cookies. So the JWT path can
NEVER authenticate a GET of an HTML page. In this codebase the only credential
page-auth actually read was a legacy cookie set exclusively by the old Google
OAuth flow; the newer Better Auth (email/password) login set its own session
cookie that Python never looked at — so email/password users could sign in and
then bounce straight back to `/login` on the next navigation. The feature looked
"wired" (login POST succeeded, a JWT was even minted) yet was non-functional for
the actual app, and nobody noticed because every real user happened to use the
other login method. **Rule:** for any server-rendered app, auth must be resolvable
from a **cookie the backend validates**, not only a Bearer header — the header
path serves API/XHR, the cookie path serves page loads, and you need both. When
adding a new auth provider, test the thing users actually do (log in, then load a
gated page), not just that the login call returns 200. If the identity provider is
a separate service (here a Better Auth sidecar), validate its session cookie by
forwarding it to that service's session endpoint (`get-session`) over the internal
network; make the call fail *safe* (timeout/error → unauthenticated, never a 500).

## Stale root-owned `__pycache__` from Docker builds makes pytest run OLD bytecode

An app that vendors `foundation`/`foundation-ui` and has been built with Docker carries
root-owned `app/**/__pycache__` directories whose `.pyc` files were compiled *inside the
image* (their embedded co-filename is `/src/app/...`). A later local `pytest` run — as your
own user — reuses those `.pyc` when the source mtime matches, so it executes **stale test
logic**, not the code on disk. The result is phantom failures: beikost's `test_static_assets`
reported i18n keys (`nav.family`) and CSS classes (`settings-legal`) "missing" that were
plainly present in `en.js`/`styles.css`, because the cached test predated them. It reads like
a real regression or a broken working tree, not a caching artifact. **Tells:** the traceback
paths say `/src/app/tests/...` (a path that doesn't exist on your machine), and the exact
same check *passes* when you run its logic inline in a fresh interpreter. You usually can't
`rm` the dirs (root-owned, no passwordless sudo) — and even clearing them is a treadmill if
the next Docker build recreates them. **Rule:** run local pytest with
`PYTHONPYCACHEPREFIX=<writable tmp dir>` so Python reads/writes bytecode there and ignores the
in-tree root-owned caches entirely — no sudo, survives future Docker builds. Sibling of the
egg-info-timestamp trap (same root cause: Docker's build user owns artifacts inside the
submodules); if an editable install *or* a test run misbehaves, check `ls -ld` for root-owned
build output first.

## The emergency `deploy.sh` rsyncs the WORKING TREE — uncommitted WIP ships to prod

`deploy.sh` (the fallback for when Actions is billing-blocked) does `rsync -az --delete` of
the local working directory to the VPS and builds there — so whatever is in the tree ships,
**including uncommitted or untracked changes that were never reviewed, tested in CI, or
merged**. This is unlike the release.yml path, which builds from the pushed git ref. During
the Better Auth Phase-2 rollout, beikost's tree carried a half-finished family-page feature
(untracked `family.html`, modified routers/locales) alongside the intended auth change; a
naive `./deploy.sh` would have pushed that WIP to production. (It happened to get wiped by
the working-tree-reverting linter first — see that lesson — but relying on that is luck, not
safety.) The in-image test gate does NOT catch this: WIP that compiles and passes tests still
ships even though it wasn't meant to. **Rule:** before an emergency `deploy.sh`, verify the
tree is exactly the intended ref — `git status --short` clean (bar the deploy script itself)
and `git rev-parse HEAD == origin/master`; `git stash -u` any stray WIP first, deploy, then
restore. Treat deploy.sh as "ship my working directory," not "ship master."

## Run the local suite under CI's Python version, not whatever's on PATH

An agent's machine may default to a newer Python than CI uses. Running the app
suite under it produces **phantom failures that CI would never hit** — and they
look like real regressions. Concretely (2026-07-16, gs-app): the local default was
Python 3.13, but every app targets **3.12** (the `python:3.12-slim` prod image; the
reusable `app-ci.yml` defaults `python_version: "3.12"`). Under 3.13, three
`test_discovery.py` tests failed with `DeprecationWarning: 'count' is passed as
positional argument` from `re/__init__.py` — a deprecation that **only exists in
3.13** — surfacing because the code calls `re.sub(..., count)` positionally and
pytest is configured `filterwarnings = error`. The change under test (legal links in
Settings) had nothing to do with discovery; the failures were pure interpreter skew.
Chasing them as a real bug wastes time, and — worse — "fixing" them to satisfy 3.13
can churn code CI is fine with. **Rule:** before trusting a local run, match CI's
interpreter — read the app's `Dockerfile` (`FROM python:3.12-slim`) and the CI
`python_version` input, and build the venv with that exact minor (`uv venv --python
3.12`). If a failure only reproduces under a *different* Python than CI's, it's
environment skew, not a regression — re-run under CI's version before acting. (It is
still worth noting forward-compat debt like the positional-`count` call, but that's a
separate, non-blocking cleanup — not a reason to fail the current change.)

## A just-deployed UI change that "looks broken" is often the tester's stale cache — incognito is the discriminator

After deploying the Better Auth button flip, 3 of 6 apps appeared broken in the browser — the
Google button "did nothing, no redirect, no error" — while 3 worked. Hours went into diffing
config, foundation versions, auth-service health, cookies, CSRF/Origin, and callbacks across a
"working" and a "failing" app. They were **byte-identical server-side** (same HTML, same JS,
same everything); the failing apps were simply serving the tester's **stale browser cache** on
those domains (leftover from repeated migration testing). The trap: the login HTML was
`Cache-Control: no-store`, so "it can't be cached" felt safe — but bfcache (back/forward
restore) and cached *sub-resources* still presented a stale page, and browser extensions
(off in incognito) can silently block the request too. **Rule:** before deep-diving a
"deploy looks broken" report where the served bytes are verifiably correct, first rule out the
tester's client state — have them try **incognito** (one step: clean cache, no extensions). If
incognito works, it's local cache/bfcache/extensions, fixed by `Ctrl+Shift+R` / clear-site-data,
not a server bug. `no-store` on the document does NOT guarantee the tester sees fresh JS. Sibling
of the "assert the real mechanism, not a proxy" traps — verify against a clean client, not a
primed one.

**CORRECTION (this exact incident was NOT cache).** The "3 of 6 apps broken, retrying fixes it,
incognito works" pattern above was later root-caused to an **intermittent server-side auth
failure** — the shared `auth-service` Docker DNS round-robin (see the next entry). "Incognito
works" was *luck*: the internal get-session call randomly hit the correct sidecar that time. The
real lesson is the meta-one: an **intermittent** bug mimics a cache bug (works sometimes, "clears"
on retry), and a single "incognito works" is a false all-clear. Before concluding "client cache,"
confirm the failure is **deterministic** (fails every clean attempt); if it's flaky across
identical clean clients, suspect an intermittent server/infra cause, not the browser.

## A per-app sidecar addressed by its bare compose service name round-robins across every stack on a shared network

Every app's Better Auth sidecar is the compose service `auth-service`, and every one is attached
to the **shared external** `mail` and `traefik` networks. Docker Compose adds the *service name*
as a network alias on **every** network a service joins — so all six apps' sidecars answer to
`auth-service` on those shared nets. An app that validates a session server-to-server via
`http://auth-service:3000/api/auth/get-session` therefore has Docker DNS **round-robin across all
six sidecars**. When the call lands on a *foreign* app's sidecar, that sidecar checks the session
cookie against **its own `BETTER_AUTH_SECRET`** → signature mismatch → returns `null` → the user
is bounced to `/login`. With six sidecars it fails ~5/6 of the time, per call.

Why it burned a full day to find:
- **Intermittent**, so it mimics a browser-cache bug: "some apps work, some don't," "refresh a few
  times and it works" (you're re-rolling the DNS dice). It was initially mis-filed as stale cache
  (see previous entry).
- The auth service **always says you're logged in** when you ask it directly, because the *browser*
  reaches the *correct* sidecar through Traefik (Host-routed). Only the app's **internal** call is
  randomized. The diagnostic tell: `browser → /api/auth/get-session` returns the full valid
  session, but the app's own auth-gated pages 401 for the same cookie. That gap = the internal
  call diverging from the public path.
- App request-time logs did not surface (single uvicorn, `PYTHONUNBUFFERED=1`, yet WARN-level
  bridge logs never reached `docker logs`), so log-based diagnosis was blind and every layer
  looked byte-identical to a "working" sibling.

**Rule:** never let a per-app service be reached by the bare compose service name when that service
is also attached to a **shared external network** — the service-name alias collides across every
stack on that network and Docker DNS round-robins silently. Give each app's sidecar a **unique
`container_name`** (e.g. `nebenkosten-auth-service`) — or a unique per-app network alias — and point
`AUTH_INTERNAL_URL` at that unique name, so the internal call can only ever reach its own sidecar.
Verify it resolves to exactly one container (`docker ps --format '{{.Names}}' | grep -c '^<name>$'`
→ `1`). This applies to any server-to-server call between co-located multi-tenant stacks, not just
auth. Corollary: an intermittent auth "logout" that clears on retry is a validator-identity bug
(wrong backend, rotated/mismatched secret), not a session-expiry or cache bug.

## When Actions is down, `deploy.sh` ships the app but NOT the sidecar — build the sidecar on the VPS

The emergency `deploy.sh` rebuilds and restarts the **app** image (it has a `build:`), but the Better
Auth sidecar is declared as `image: ghcr.io/…/auth-service:${AUTH_SERVICE_TAG:-latest}` with **no
`build:`** — so `docker compose up -d --build` rebuilds only the app and leaves the sidecar on
whatever `:latest` is already on the VPS. Normally `release.yml` (GitHub Actions) builds+pushes the
sidecar image to GHCR; when Actions is budget-blocked, nothing refreshes it, so an app change that
needs a new sidecar (new column, new hook) silently ships half the change. Pulling the new image on
the VPS also fails (`unauthorized` — the images are private and the VPS isn't logged into GHCR), and
piping a token to `docker login` over SSH is both risky and gets blocked by the agent safety
classifier. **Rule:** to ship a new sidecar without Actions, build it **on the VPS** from the source
`deploy.sh` already rsynced — `docker build -t ghcr.io/<owner>/<app>-app/auth-service:latest
packages/foundation/auth-service` then `docker compose -f docker-compose.yml -f docker-compose.prod.yml
up -d --no-deps --force-recreate auth-service`. No GHCR login, no token, no `write:packages` scope is
needed — pushing the image to GHCR is NOT required for the deploy (it only keeps `:latest` current for
the eventual real release).

## A column read on every authenticated request must exist BEFORE the new app serves — pre-apply the DDL

The Better Auth `"user"` table is owned by the sidecar (its boot `applySchema` runs the DDL), but the
app `depends_on: auth-service: condition: service_started` — **`service_started`, not
`service_healthy`** — so the new app can start serving before the sidecar has applied a new column.
When the engine lock gate does `SELECT disabled FROM "user"` on *every* authenticated request, a
missing `disabled` column 500s every authenticated page for the whole deploy window — and indefinitely
if `applySchema` ever fails. **Rule:** when a deploy adds a sidecar-owned column the app reads on the
hot path, pre-apply the idempotent DDL to each prod DB *before* deploying the app — `docker exec
<app>-db psql -U <user> -d <db> -c 'ALTER TABLE "user" ADD COLUMN IF NOT EXISTS disabled BOOLEAN NOT
NULL DEFAULT FALSE'` — so the column exists regardless of sidecar timing; the sidecar's own `ADD
COLUMN IF NOT EXISTS` then no-ops. (Or make the read fail-open on a missing column, like the
`registration_enabled` "table missing → open" pattern.) Verify with a canary:
`docker logs --since 3m <app> | grep -c ' 500 \|UndefinedColumn'` → `0`.

## `runner_name: ""` + `steps: []` on a fast-failing run = a billing/quota block, not a fixable bug

A run that goes to **`failure`** (not `startup_failure`) in ~4–5s with jobs *listed* looks like a real
job failure, but if the first job has `runner_name: ""` and `steps: []` (via `gh api
/repos/<o>/<r>/actions/runs/<id>/jobs`), GitHub **scheduled the jobs but never assigned a runner** —
the Actions minutes budget is exhausted. `gh run view --log-failed` says `log not found` because no
step ever ran. Don't confuse it with the read-only-permissions trap (that yields `startup_failure`
with **0** jobs) — rule that out with `gh api …/actions/permissions/workflow`
(`default_workflow_permissions` should be `write`). **Rule:** before building elaborate manual-deploy
workarounds, confirm the pipeline is truly dead this way (or just cut one release and watch the run),
rather than inferring "billing" from CI alone — and remember the budget resets on the monthly rollover.

## "Legacy code removed?" needs a table-READ audit, not a removed-symbol grep — kept data tables go stale

When a migration removes the old *write* path (e.g. the legacy auth code) but deliberately KEEPS the
old DATA tables, "is the legacy stuff gone?" cannot be answered by grepping for the deleted symbols
(`foundation.auth.sessions`, `fdn_session`, `upsert_oauth_user`, …) — that search passes while feature
code still READS the kept tables. Worse, those reads silently go stale: once the new authority (Better
Auth) stops back-filling the old tables, any entity created AFTER the cutover is missing from them, so
email→user lookups, member/permission lists, and user-count stats return empty/wrong — broken in prod
for exactly the newest users, and invisible to a green suite that seeds the old tables. This bit the
wolf-labs fleet: after the Better Auth cutover, share/invite-by-email and the hub's user counts were
quietly broken for every post-migration signup, and a "legacy auth code removed?" audit (a symbol grep)
came back clean and was reported as done — the *reads* were never checked. **Rule:** when a change
retains tables/columns but redirects their writer, audit the READERS — grep every app for the table
names AND the model classes (`users`, `user_pii`, `UserPii`, `AppSession`, `oauth_identities`, …), not
just the removed functions — and make "does any feature still read the kept table?" the completeness
bar. If the retained data is a mirror the new authority no longer updates, repoint every reader to the
authority in the same change (then the tables can be dropped), or explicitly flag the readers as
known-stale. Never let a symbol-search stand in for a completeness check, and never answer a
"is it all done?" question from a narrower grep than the question implies.

## Server-to-server auth-validation calls share one `no-trusted-ip` rate-limit bucket → random logouts

The Python engine validates every authenticated *page* load by calling the Better Auth sidecar's
`/api/auth/get-session` server-to-server (internal Docker network). Those internal calls carry no
client IP, so Better Auth's per-IP rate limiter pools **all** of them under a single `no-trusted-ip`
key at the default 100/60s. A single active user clicking around (or one burst — a form submit that
reloads a data-heavy page) trips 429 on that shared bucket, the session bridge turns the 429 into a
logout, and re-login is ALSO throttled (`/sign-in` limited) → the user is "randomly logged out and
can't get back in", intermittently, with nothing wrong with their session. It reads exactly like the
DNS-collision logout bug but is a different cause — check the app log for
`get-session unexpected 429` and the sidecar's `"rateLimit"` table for a `no-trusted-ip|/get-session`
key. **Rule:** never rate-limit the session-validation endpoint at page-load rates — exempt
`/get-session` in the sidecar's `rateLimit.customRules` (it only reads session state; keep
sign-in/up/reset strictly limited) — AND make the validation client treat a 429 like a 5xx (transient,
retried, log-and-deny) rather than an instant session eviction. A throttle on a *validation* call is
never a "no session" verdict. Immediate mitigation for a live incident: `DELETE FROM "rateLimit"` on
the app's DB resets the windows.

## Setting up version tags when Actions is budget-blocked: `git tag`, not `gh release create`

When you need release *tags* on GitHub but the deploy pipeline can't run (Actions minutes exhausted —
see the `runner_name: ""` entry), create plain annotated git tags
(`git tag -a vX.Y.Z <sha> && git push origin vX.Y.Z`), NOT `gh release create`. In this repo family
`app-release.yml` triggers on `release: types: [published]`, so a raw tag push does nothing, but
publishing a Release fires the (runner-less) workflow → an instant `startup_failure` in every repo.
Tags give you the version markers on GitHub with zero workflow noise; when budget returns, promote a
tag to a Release to run the real build+deploy and reconcile prod with the tag. Two traps when
back-filling tags across the fleet in a loop:

1. **Validate the derived version is non-empty BEFORE tagging/pushing.** A quoting slip in
   `ver=$(git show $ref:path | grep '^version' …)` — an unquoted ref containing a slash
   (`origin/master`) — silently yielded an empty string, so `tag="v$ver"` became a literal `v`, and
   the loop pushed a garbage `v` tag to all six remotes before anything flagged it (then had to be
   deleted from every remote). Guard the publishing step on the computed input
   (`[ -z "$ver" ] && { echo abort; return 1; }`), and prefer reading the checked-out file
   (`grep '^version' app/pyproject.toml`) over `git show ref:path` inside a loop.
2. **Tag the DEPLOYED commit, not master HEAD.** When prod is behind master — an undeployed or broken
   commit sits on the tip (e.g. another agent's in-flight PR that won't build) — tag the commit that's
   actually live (`git tag vX.Y.Z <deployed-sha>`), or the tag misrepresents what's running.

## An auth-migration ETL must copy EVERY profile field (image!), and OAuth providers only seed profile at sign-up

Two compounding gaps made every migrated Google user show a blank avatar after the legacy→Better Auth
cutover. (1) The one-time ETL (`auth-service/src/etl.ts`) inserted `"user"` with only
`id, name, email, emailVerified` — it silently dropped `image`. So the Google avatar URL that lived in
the legacy `users.image` never reached Better Auth's `"user".image`. (2) Better Auth (like most OAuth
libraries) maps the provider profile — name, **image** — onto the user row ONLY at *sign-up*, not on
subsequent sign-ins, so an account created any other way (an ETL, an admin insert) never gets its
image, and re-logging-in doesn't fix it. It stayed invisible because the legacy `users.image` column
was still being read for avatars until a later refactor repointed reads to `"user".image` (empty) and
dropped the legacy table — turning a dormant data gap into a visible regression. **Rule:** when you
ETL identities into a new auth system, copy the WHOLE profile (image/avatar included), not just the
login-critical id/email/name — and verify with `SELECT count(*) WHERE image IS NULL` on the target.
For the provider itself, if you want image/name kept fresh (or backfilled for non-sign-up accounts),
set the "override user info on sign-in" flag (`socialProviders.<p>.overrideUserInfoOnSignIn: true` in
Better Auth) — providers re-send the picture on every login, so it self-heals on next sign-in even
after the source data is gone (note: this also refreshes the name from the provider each login).

## A stale-based branch silently REVERTS a concurrent submodule pin bump on merge

A submodule gitlink (`packages/foundation`, `packages/foundation-ui`) is **tracked
content**, so a PR carries whatever submodule SHA its branch was cut from. When two
agents work the same repo family: agent A bumps the pin (e.g. foundation-ui 0.11.0 →
0.14.2) and merges; then agent B merges a branch **branched before** A's bump, and
B's merge **silently reverts the pin to the stale SHA** — B never touched the
submodule, but its old gitlink wins. If the app's code now depends on the newer
submodule, this breaks `master`. It bit the settings-migration session: an auth PR
(branched pre-migration) reverted **scuba** foundation-ui 0.14.2 → 0.11.0, and the
migrated `settings.html` includes `shell/_settings_hub.html` (a partial only in
≥0.14.0), so authenticated `/settings` 500'd; it also downgraded **beikost** 0.14.2 →
0.14.1. In review a pin bump and a pin *revert* are indistinguishable — a one-line
40-hex change — and the break only shows for authed users (unauth `/settings` just
307-redirects, masking it). The agent-lock publish lease does NOT prevent this: the
collision is in the *content* of a stale branch, not the push race. **Rule:** before
merging ANY PR in a repo where submodules are in play, `git fetch origin && git rebase
origin/master` so a stale gitlink can't clobber a concurrent bump; and after any merge
into a repo whose submodule you bumped, verify the pins with
`git ls-tree origin/master packages/foundation packages/foundation-ui` — do a
family-wide pin audit at the end of any session that touched submodules. A hub-and-spoke
template paired with a pre-0.14 foundation-ui pin is the tell; the fix is a re-pin +
redeploy.

## A cross-session handover doc can invent a "requirement" and attribute it to the owner

When one agent session hands work to the next, it writes a handover doc (`docs/HANDOVER-*.md`)
listing follow-up tasks. The receiving agent treats that doc as ground truth — and that is the
opening for a subtle trap: the authoring agent can frame its OWN design idea as a user
requirement, e.g. `**Goal (owner's words):** ...`, for a feature the owner never actually asked
for. Nothing in the doc looks false; the receiving agent has no signal to distrust it, so it
starts building (worktree, skill load, data investigation, sometimes a whole feature) before
anyone checks with the human. It bit the nebenkosten AI follow-ups: a "Task A — AI-added data
visualizations" (bar/line charts attached to the reviewer's findings) rode across sessions
attributed to "the owner's words"; when the owner was finally asked in passing they said "I
never asked for that — where's this from?" and it was dropped. Wasted setup, and — worse — it
nearly shipped unrequested surface area (an AI chart renderer + schema) into a **money app**.
The `(owner's words)` label is what launders an agent's proposal into a requirement. **Rule:**
treat inter-session handover tasks as **proposals, not requirements** — especially *net-new
features* (finishing half-built work or fixing a named bug is different). Before building
anything net-new that a handover attributes to the owner, confirm it with the actual human in
one line first. And when *writing* a handover, keep the two apart: quote the real ask under
"the owner asked for X", and mark your own ideas plainly as "I recommend X next" — never blur
them into "(owner's words)".

## When an approved mock-up exists, show a faithful visual mock BEFORE wiring the UI

When the owner has an approved design (`app/mockups/*.html`, a Figma export, a handoff) and asks
for "exact implementation", building function-first and treating the visuals as an afterthought
reads as *ignoring the mock-ups* — even when you believe you're following them. The trap is
subtle: the approved mock is usually drawn for one context (a full **page**), and the task
re-homes it into another (a **popup**, a drawer, a card). That translation is where an agent
quietly substitutes its own layout/framing, ships it, and the owner says "it looks nothing like
the mock-ups / you keep ignoring them." It cost real back-and-forth on nebenkosten's KI-Assistent
popup: several rounds of "where's the input field", "use normal chat bubbles", "show me the PC
view" that a mock-first pass would have surfaced in one. **Rule:** for any UI where an approved
design exists, produce a **faithful visual mock and get sign-off before implementing** — and make
it faithful by *reusing the design's own stylesheet verbatim* (extract the mock-up's `<style>`,
drop the approved markup into the new shell, add only the shell CSS), not by hand-reconstructing
classes (which drifts). Render it for the owner (an artifact / a sent HTML file), including the
**breakpoints they'll actually use** — mock the desktop *and* mobile composition, since a preview
panel often shows only one. Treat visual approval as a **gate**, not a courtesy: cheap alignment
up front beats implement-then-rework. Sibling of the "assert the real mechanism, not a proxy"
traps — the real mechanism here is the owner *seeing* the pixels, not your description of them.

## Running an app's tests from a worktree uses the shared venv's editable submodules — the MAIN checkout's, which are often stale

The concurrent-agents workflow says do non-trivial git work in a private worktree
(`git worktree add … origin/master` + `git submodule update --init --recursive`), so the
worktree's `packages/foundation` and `packages/foundation-ui` sit at the commits `origin/master`
pins — current. But there is no per-worktree Python venv: you reuse the main checkout's
`.venv`, whose **editable** install of `foundation`/`foundation-ui` resolves via a `.pth`/
`__editable__` finder to `~/Dev/<app>/packages/*` — the **main checkout's** submodules, which
are whatever stale commit that checkout happens to sit at (nobody ran `submodule update` there).
So `import foundation_ui` in a worktree test run loads the *old* shell library while your
worktree app code targets the *new* one. The failure surfaces at **collection** as an API
mismatch — `TypeError: ShellConfig.__init__() got an unexpected keyword argument
'settings_profile'` — which reads like a bad app/shell call or a version-pin bug, not a
path-resolution problem, and sends you diffing shell_config against nav.py. (Same family as the
Docker root-owned `__pycache__`/egg-info traps: the module you *think* you're running isn't the
one on disk in front of you.) **Rule:** when running an app's suite from a worktree, prepend the
**worktree's** package dirs to `PYTHONPATH` so imports resolve to the submodules you actually
checked out, overriding the venv's editable finder:
`PYTHONPATH=<worktree>/packages/foundation:<worktree>/packages/foundation-ui pytest -q` (still
from `app/`, still with `PYTHONPYCACHEPREFIX` set to a writable tmp dir). Tell: a collection-time
`TypeError`/`unexpected keyword argument` on a shell dataclass right after a foundation-ui bump,
where the worktree's `git ls-tree HEAD packages/foundation-ui` differs from the main checkout's —
that's stale-editable skew, not a real API break.

## Jinja autoescape: `|e` on a `~`-operand escapes the string LITERALS too — corrupting hand-built attributes

Building an HTML attribute string by concatenation and marking it safe —
`icon_btn('edit', 'data-typ="' ~ a.typ|e ~ '"')`, later rendered `{{ attrs|safe }}` —
looks like the safe way to inject a user value into a `data-*` attribute (the macro
even documented "Frei erfasste Nutzerdaten MÜSSEN vorher escaped werden ...|e"). In an
**autoescaping** Jinja2 environment it is the opposite of safe. Applying `|e` (or any
filter that returns `Markup`) to ONE operand of the `~` concatenation makes the whole
expression escape-aware, and Jinja then escapes the **string literals** in the same
expression too — including the `"` attribute delimiters. So
`'data-typ="' ~ a.typ|e ~ '"'` renders `data-typ=&#34;Kautionsrückzahlung&#34;`, and
every value arrives at the client **wrapped in literal quotes** (`"1"` instead of `1`).
The page renders, the element exists, but JS reading `dataset.typ` gets `"…"`: a date
won't parse, a `<select>` value won't match, numbers are garbage — the classic "edit
does nothing / fields not prefilled" bug. It hides three ways: (1) only the ONE row
using `|e` breaks — sibling rows using the same `~` pattern *without* `|e` work,
because their values (dates, cents) contain no `"`, so it reads as a one-off, not a
pattern bug; (2) `|safe` at the end looks like it should make it literal, but the
damage (escaped `"`) already happened during `~`; (3) the naive fix — just drop `|e` —
makes the display correct but silently REOPENS attribute injection (a `"` in free text
breaks out of the attribute: `data-ref="x" onerror="alert(1)"`), so neither with-`|e`
nor without-`|e` is both correct and safe. It cost a full browser-repro loop on
nebenkosten's "Auszahlung an Mieter" edit. **Rule:** never hand-build an HTML attribute
string with `~` + `|e` + `|safe` in an autoescape env. To pass server data to client
JS, emit it with **`| tojson`** (XSS-safe *and* autoescape-safe) into a JS variable and
carry only safe scalars — an integer id — on `data-*` attributes, then look the record
up by id client-side. If a value must sit in an attribute, let autoescape do the work
(`attr="{{ value }}"`, a bare substitution), never a `~`-concatenation you then mark
`|safe`. Verify the RENDERED attribute in a browser (`getAttribute`) — a value that
comes back quote-wrapped (`"1"`) is this bug; sibling of the "assert the real mechanism,
not a proxy" traps.

## Inline validation on blur inserts an error box that shifts layout and eats the click — Cancel needs two clicks

A form with live inline validation (validate a field on `focusout`/blur and insert an error
message below it) has a nasty interaction with any button in the same dialog: clicking
"Abbrechen"/"Cancel" (or even "Save") first **blurs** the focused required field, so the blur
handler inserts the "required" error box, which **grows the layout and shifts the buttons down
between mousedown and mouseup** — so the click lands on nothing and is lost. The user has to
click the button **twice**: the first click only reveals the error, the second (layout now
stable) actually activates it. It looks like the Cancel button is broken/ignored, but it is a
layout-shift-during-click race triggered by the validation the blur itself fired. It bit every
popup in nebenkosten that had a required field (kostenposition, liegenschaften, ...) once inputs
became modal dialogs — the inline validator (`NBK.liveValidate`) had always validated on
`focusout`, but only inside a dialog does the resulting reflow move the action buttons under the
pointer. Playwright can't reliably reproduce it (its element clicks are single synthetic events,
not a real mousedown->shift->mouseup), so it hides from e2e and only a real mouse shows it.
**Rule:** an on-blur/focusout inline validator must NOT insert an error (and reflow) when focus
is leaving the field to activate a **button** — check `event.relatedTarget` and early-return if
it is (or is inside) a `<button>` (`relatedTarget.closest('button')`). Real submits still
validate everything on click; field-to-field navigation (relatedTarget = another input) still
validates live. More generally: never let a blur handler mutate layout above/around the control
that is about to receive the click — reserve the error's space, position it out of flow, or skip
it for button targets. Verify by focusing a required field and moving focus to the Cancel button
(`el.focus()`): the error box must stay hidden. Sibling of the "held identity transform breaks
top-layer dialog hit-testing" trap — both are "the click didn't land where it looked like it
would" dialog-interaction bugs.

## Never hold the agent-lock lease across a hang-prone step (rebase/build/deploy)

The `standards/agent-lock.sh` publish lease (see the "Concurrent agents" section in
CONVENTIONS) is an atomic-`mkdir` mutex with a TTL — it serialises the publish
critical section, but it does NOT bound how long a holder holds it. So if you run
anything hang-prone *while holding it*, you block every other agent for as long as
you're wedged (up to the 15-min TTL). It bit a topbar rollout: the publish flow
acquired the lease and then did a `git fetch && git rebase origin/master` *inside*
it; master had moved, the rebase hung (conflict / editor prompt behind a `| tail`
pipe), and the command sat holding the lease for the full 2-minute timeout before
its `trap` released it — the other agent, mid-release, was blocked the whole time.
The lease was still correct (never two holders; the TTL guarantees a wedged holder
eventually frees), but a seconds-long critical section had become minutes. **Rule:**
do ALL hang-prone work — `git rebase`, test suites, `ci-local.sh`, `deploy.sh` —
*outside* the lease. Acquire it only for the actual push+merge (seconds), and the
in-lease guard must **abort** if `origin/master` moved (re-rebase OUTSIDE, then
re-acquire), never rebase while holding it. Deploys never need the lease at all
(they're SSH to the VPS, and idempotent). If you must wrap a command in the lease,
give it a hard `timeout` so a wedged step releases in seconds, not at the TTL.

## The local-test-env trap family is now one command — `./dev`, don't hand-roll it

A whole cluster of entries in this file are the *same* failure: the local test suite
silently becomes "CI-only" because setting the environment up correctly by hand is
error-prone, so people fall back to letting CI (the budget-capped monthly resource) be
the first run. Those traps — SQLite-vs-Postgres, root-owned egg-info/`build`/`__pycache__`
from Docker builds, running from the repo root and loading the production `.env`, a root
`pytest.ini` shadowing `app/pyproject.toml`, host Python 3.13 vs the 3.12 target, the
`pytest11` entry point not loading, `foundation-ui` installed non-editable dropping its
`testing/*.js`, `pytest app/e2e` adopting the wrong config and killing the server thread,
client JS never `node --check`ed, and a reused test Postgres drifting or leaking data — are
now **mechanically prevented** by a single self-healing driver, `.standards/dev.sh`, run as
`./dev {setup|db|test|e2e|check|clean}` (synced from this hub; the per-app `./dev` wrapper is
a one-line delegation). It pins Python 3.12 via `uv`, editable-installs the submodules
(foundation-ui `-e`), runs pytest from `app/` with an exported per-app localhost
`DATABASE_URL` and `PYTHONPYCACHEPREFIX`, wipes the test DB to a clean schema before each run
(CI-parity — a measured drop+full-migrate adds no observable time; suite runtime is 100% the
tests, so a golden-copy/template clone would save <2s and is not worth its staleness), and
`node --check`s the client JS. The one thing it can't self-heal — root-owned build artifacts,
no passwordless sudo — it detects and hands you the exact `sudo rm -rf` one-liner.

**Rule:** run the local suite through `./dev`, never a hand-rolled `pytest` invocation — that
is what keeps local-green a precondition for pushing rather than a fiction. The individual
trap entries above are **kept on purpose**: they are the rationale for each thing the driver
does, so a future "simplification" of `dev.sh` (drop the pycache prefix, point e2e back at
`pytest.ini`, reuse a dirty DB) can be recognized as resurrecting a known production trap.
Edit the driver at the source in this hub, never the synced `.standards/dev.sh` copy.

## A root-owned `app/static/shell` silently defeats foundation-ui's dev shell-refresh

foundation-ui's shell bundle (JS/CSS/fonts) is **copied** into each app's `app/static/shell`
— not symlinked (Starlette `StaticFiles` refuses paths escaping the mount, so a symlink 404s).
`foundation_ui.ensure_static_link()` refreshes that copy on every boot (`shutil.rmtree(target)`
then `copytree(src)`) so edits to the shell bundle are picked up on restart. But it is
best-effort and swallows `OSError`: if `app/static/shell` is **root-owned** (written by a prior
Docker build, like the egg-info/`__pycache__` traps), the `rmtree` fails silently and the STALE
copy persists forever. Every foundation-ui shell change (a `shell.js` fix, a CSS tweak) then
**never reaches the app locally** — the app serves the old bundle, and edits appear to do
nothing. It cost real time diagnosing why a shell.js fix wasn't served (the served copy and the
submodule source silently disagreed). **Rule:** if a foundation-ui shell/JS/CSS change doesn't
take effect locally, check `ls -ld app/static/shell` — a root-owned copy is the culprit; clear
it (`sudo rm -rf app/static/shell`, no passwordless sudo so hand it to the human once) and let
`ensure_static_link` recopy it (owned by you) on the next boot. Same family as the other
root-owned-Docker-artifact traps.

## A `DOMContentLoaded`-only init silently dies if the script loads after it fires

Registering a page's whole init behind `document.addEventListener("DOMContentLoaded", fn)` with
**no already-loaded fallback** means: if the script executes *after* `DOMContentLoaded` has
already fired (loaded late/deferred, served from cache, or re-executed), the listener misses the
event and nothing runs. foundation-ui's `shell.js` did exactly this — so when it happened to run
post-DCL, the ENTIRE shell (drawer, **settings profile form**, **logout confirm dialog**,
password form, theme/focus controls) was left uninitialised, while the top-level code (which
defines `window.FDN`) still ran, so it *looked* loaded. Invisible for ages because nothing
exercised the settings pages until the cross-stack e2e did — then one guard fixed the
profile-update, logout-confirm, AND dark-mode focus-gate failures at once. **Rule:** any script
that registers init on `DOMContentLoaded` must guard for the already-fired case:
`if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot); else boot();`.
Tell: top-level globals exist but nothing the init wires up works, with no JS error.

## A backup can report success every night while backing up nothing

The VPS restic backup ran green-looking for ~24 days while three independent
defects hollowed it out — each invisible because the *symptom* of a broken backup
is silence. Found only by auditing the live repository, not the logs.

1. **`set -e` turns one broken source into a skipped retention pass.** The script
   ended with an invalid `restic backup --stdin --stdin-filename k <path>` (restic
   rejects `--stdin` *plus* a path). It aborted there every night, so the last
   source was never captured **and `restic forget --prune` never ran at all**. A
   backup script must treat each source as independently fallible: record the
   failure, keep going, always run retention, and exit non-zero with a summary.
2. **`restic forget` silently keeps everything when snapshots come from
   `docker compose run`.** Default grouping is `host,paths`; `compose run` assigns
   a *fresh random container hostname* per run, so every snapshot forms a group of
   one where `--keep-daily 7` keeps it forever. Prune reports success and deletes
   nothing (measured: 136 snapshots, 28 distinct hostnames, 28 groups of one for a
   single source). **Rule:** `restic forget --group-by paths`, and pin `hostname:`
   in the compose service.
3. **`pg_dump | restic backup` hides a failed dump behind restic's exit code**, so
   a truncated or empty dump is snapshotted as if it were good. Dump to a file,
   assert it is non-empty, *then* snapshot it.

Two more traps in the same family, hit while fixing the above: with one snapshot
per source, bare `latest` means *whichever source ran last* — always select with
`restic dump/restore --path /x`, or the restore silently reads the wrong snapshot;
and `docker compose up -d <container-name>` is not valid (`<app>-db` is the
container, `db` is the service).

**Rule:** a backup is unverified until you have (a) read the tail of the last run
and seen an explicit success marker, (b) counted snapshots per source against the
retention policy — not just "prune said OK", and (c) restored every source into a
throwaway database and checked table/row counts. Coverage rots silently too: new
apps must be added to the backup in the same PR that deploys them, or they run in
production for months with no backup at all (four of six apps did).

## A service that starts before its data source reports healthy forever

CrowdSec on the VPS ran for three weeks with **no datasource at all**. It started
before Traefik had created `/var/log/traefik/access.log`, logged one line about
the missing file, and then looked perfectly healthy: process up, agent registered,
heartbeats every 60s, community blocklist downloading and applying 2400 bans. What
it never did was read a single log line, so no local scenario could ever fire.
`cscli metrics` showed empty Acquisition/Parsers/Buckets tables while the Local API
tables had data — the tell. Restarting once the file existed fixed it instantly.

This is the same shape as `restic forget` keeping everything and `docker image
prune` freeing nothing: **the failure mode of a monitoring/cleanup component is
silence, which is identical to its success mode.** You cannot notice it by
watching; you have to assert on throughput.

Compounding it, the obvious health check lies in the reassuring direction:
`cscli decisions list` **hides community-blocklist (CAPI) decisions unless `-a`
is passed**, so a working CrowdSec reports "0 active decisions" — which reads as
broken — while a truly dead one reports the same thing.

**Rules:**
- A file-tailing datasource that does not exist at start-up is skipped, not
  retried. If service A tails a file written by service B, either guarantee the
  ordering or verify ingestion after every restart of A.
- Health-check components on **work done, not liveness**: lines read, snapshots
  per source, bytes reclaimed. "The process is up" and "the last run exited 0"
  both pass while the component does nothing.
- Before believing a zero, check whether the CLI filters by default (`-a`,
  `--all`, `--include-*`). A zero that means "hidden" and a zero that means
  "broken" are indistinguishable in a report.

## `restart: unless-stopped` can silently not come back after a reboot

A host reboot brought back 20 of 21 containers. The exception was **Traefik** —
so all six apps were healthy, every database was up, and the entire site was
unreachable, because the reverse proxy is the single point of entry. It stayed
down until someone ran `docker start traefik` by hand 11 minutes later.

Traefik exited cleanly (code 0) during shutdown like everything else. On boot,
dockerd logged `Loading containers: start.` → `Restoring containers: start.` →
`Loading containers: done.` with **zero references to that container ID**
anywhere in the daemon log. It was never even considered for restore.

`unless-stopped` means "restart unless the container was manually stopped", and a
stop performed while the daemon itself is shutting down can leave a container in
that state — non-deterministically, which is why 20 siblings with the identical
policy came back. `always` restarts unconditionally on daemon start.

Note the shape: every health signal was green. The apps were up, healthy, and
serving on localhost; only the ingress was missing. A container-level check that
asks "are the app containers running?" passes perfectly during a total outage.

**Rules:**
- Entry-point and infrastructure services (reverse proxy, IDS, mail relay) use
  `restart: always`, never `unless-stopped`. Where being down means *everything*
  is down, unconditional restart is worth more than honouring a manual stop.
- After any reboot, verify the **externally observable** thing (an HTTPS request
  from off-box), not the container list.
- Verify a restart-policy change by restarting the Docker daemon
  (`systemctl restart docker`) — it exercises the same restore path as a boot,
  so you learn now rather than during the next unplanned reboot.

## Migrating an app onto the shared `app-ci.yml` exposes it to gates it never ran — and workflow files need SSH to push

Converging a repo with a **bespoke `ci.yml`** onto the shared reusable workflow
(`flowolf86/.github` → `app-ci.yml`) is not a clean swap: the shared workflow runs
**mypy** and a **coverage-gated `quality` job** the app's old CI never did, so a
never-type-checked app fails the migration on day one. nebenkosten had **90 mypy errors**
its old lint (compile + `node --check` only) never surfaced — the migration was blocked
until every one was fixed. **Rule:** before replacing an app's bespoke CI with the thin
caller, run the *new* gates locally first (`./dev` gives mypy; measure coverage to pick a
truthful `coverage_threshold`) — treat the latent debt as part of the migration's scope,
not a surprise the first CI run reports. Fix type errors behavior-neutrally (annotation
widening, `type[Any]` for generic model holders, `_dreq`/`cast` for schema-nullable-but-
logically-required columns) and prove it with the **unchanged** test suite; a green suite
after the type pass is what certifies you changed no behavior (critical on a money app).

Second trap in the same task: **pushing a branch that adds/edits `.github/workflows/*` over
an HTTPS remote is rejected** — `refusing to allow an OAuth App to create or update workflow
… without workflow scope` — because the cached HTTPS token lacks the `workflow` scope. The
code push works; only the workflow-file push fails, which reads like a branch-protection or
repo-permission problem. **Rule:** push workflow-file changes over **SSH**
(`git push git@github.com:<owner>/<repo>.git <branch>`), which uses your key, not the
scope-limited token. (`gh pr merge --squash` server-side is unaffected — the scope check is
only on the client push.)
