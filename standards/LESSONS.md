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
