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
- **A merge is not a release, and not every PR earns one.** Merging a PR to
  `master` is decoupled from cutting production — merge freely, release
  deliberately. When a piece of work spans **several PRs on one topic** (e.g. a
  feature split into stages, or a batch of related fixes), land **all** of that
  topic's PRs on `master` first, then cut **one** release for the whole topic —
  don't release after each intermediate PR. The version bump still rides the PR
  that makes the change user-facing; the *release tag* just waits until the topic
  is fully merged. Release when the human asks, or when a self-contained topic is
  complete — never reflexively after each merge. (You may still bump the version
  in each PR as you go; a release simply ships whatever version `master` currently
  carries.)
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
- **Local verification is a SUPERSET of CI. This is the rule; everything else in
  this section is how you satisfy it.** Not "the tests I usually run", not "the
  suite" — *every check CI performs*, run locally, **under the runtime versions CI
  pins, with the same services, the same flags, and the same commands**. If CI runs
  three jobs, local-green means you ran three jobs. Waiting for CI must never be
  the only way to learn whether a change works, because CI is budget-capped and
  goes away for weeks at a time (see LESSONS); a repo whose truth lives only in CI
  is a repo you cannot ship from in the second half of the month.

  Four obligations follow, and they are not optional:

  1. **One command runs the whole gate.** Every repo exposes a single entry point
     — `./dev check`, `make test` — that runs *everything* CI runs. Invoking the
     pieces by hand is how jobs get silently skipped. Never hand-roll `pytest`,
     `vitest`, or `npm test` when the repo has a driver.
  2. **CI is derived from local, never the reverse.** The Makefile / `dev.sh` is
     the source of truth; the workflow mirrors it. **A CI step with no local
     equivalent is a bug in the repo** — fix it before your next PR, don't route
     around it. Equally: a local step *weaker* than its CI counterpart (no
     database, no coverage gate, fewer flags) is the same bug wearing a disguise,
     and it is worse because it looks like coverage.
  3. **Claiming green requires enumerating.** A PR that says "local-green" lists
     **each CI job and its local result**. "Tests pass" is not a claim, it is a
     vibe. If some part genuinely cannot run locally, name that part, say why, and
     say what you ran instead — never let the reader infer full coverage from a
     partial run.
  4. **Match CI's pinned versions.** Same Python minor, same Node major, same
     Postgres major. A suite that is green on your host and red on CI's runtime
     was never verified — and the reverse (green on CI, red locally) usually means
     CI is passing by luck, which is worth finding.

  Local-green is a *precondition* for triggering CI, never a fallback, and never
  "just when the budget is low."
- **Run the local suite through `./dev`, not a hand-rolled `pytest`.** `./dev test`
  (and `./dev check` for the full gate, `./dev e2e` for Playwright) is the self-healing
  driver — synced from this hub as `.standards/dev.sh` — that pins Python 3.12,
  editable-installs the submodules, and runs from `app/` against a throwaway per-app
  Postgres wiped clean each run, mechanically preventing the "suite is CI-only" trap
  family (see LESSONS). **New apps get the driver via standards sync and add a 2-line
  root `./dev` wrapper** (`exec bash "$(dirname "$0")/.standards/dev.sh" "$@"`) as a
  bootstrap artifact, alongside the `CLAUDE.md` / `.standards/` / `sync-standards.yml`
  wiring. The manual invocation below is the underlying mechanism `./dev` automates.
- **Run the unit suite from the app directory (`cd app && pytest -q`), never the repo
  root.** `env_file=".env"` is cwd-relative, so a root run loads the *production*
  `.env` and admin/registry tests fail on the CSRF origin check — failures that read
  as real regressions. CI runs from `app/`. (The e2e suite is the exception: it runs
  from the root against `pytest-e2e.ini` and sets its own env.) See LESSONS.
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

## Concurrent agents on the same repo (isolation + publish lease)

Multiple agents (Claude sessions, the human, scripts) routinely operate the same
`~/Dev` repo at once. A single git checkout's `HEAD`, index, and working tree are
**global mutable state**, so this produces two distinct classes of conflict — each
needs its own fix. Getting these wrong has cost real work (a lost commit recovered
from `reflog`; two sessions colliding on the same version number; a mislabeled
release).

**Class A — working-tree / HEAD collisions** (a linter reverts your files, HEAD
moves mid-command, your branch gets force-pushed with someone else's commit).
**Fix: isolation.** Do every non-trivial git edit in a private worktree, never in
the shared checkout:

```sh
git fetch origin
git worktree add -b <type>/<slug> /tmp/<slug>-wt origin/master
cd /tmp/<slug>-wt
git submodule update --init --recursive     # worktrees don't populate submodules
# …edit, test, commit, push from HERE…
```

Its HEAD/index/tree are immune to the main checkout's churn. Tag-secure any good
commit immediately (`git tag -f recover/<slug> <sha>`) and verify the TRUE remote
with `git ls-remote origin <branch>` — never trust the local tracking ref. Remove
the worktree when done (`git worktree remove --force <dir>`).

**Class B — publish races** (two agents pick the same version, both merge to
master, a tag ends up mislabeled). Worktrees do NOT fix this — the collision is on
the shared remote during the short "choose version → push → merge → tag" window.
**Fix: serialize that critical section per repo with the shared advisory lease,**
`standards/agent-lock.sh` (synced to every repo at `.standards/agent-lock.sh`). It
is an atomic-`mkdir` lease with a TTL, so an agent that dies mid-publish can't
deadlock the repo — a stale lease is broken automatically on the next acquire:

```sh
LOCK=.standards/agent-lock.sh                     # or ~/Dev/dot-github/standards/agent-lock.sh
TOKEN=$(AGENT_ID="$(id -un)/session" bash "$LOCK" acquire <repo-name>) || exit 1
trap 'bash "$LOCK" release <repo-name> "$TOKEN"' EXIT
git fetch origin && git rebase origin/master      # pick the version AFTER acquiring
#  …bump pyproject version, push, gh pr merge --squash --admin, gh release create…
```

Acquire the lease **before** reading `origin/master` to choose the next version, so
two agents can't both claim `vX.Y.Z`. Hold it only for the publish steps (default
TTL 15 min; `agent-lock renew` if a publish genuinely runs long); editing and
testing in a worktree need no lock and stay fully parallel. `agent-lock status
<repo>` shows the current holder.

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

## Comments describe the code that is there, not the code that was

A comment earns its place by making the **current** code easier to understand. A
comment that narrates history — what this used to be, which file it was ported
from, what a deleted test asserted, which migration stage it is in — is noise. It
grows with every change, is never re-verified, and eventually contradicts the code
beside it. The reader then has to work out which of the two is lying.

**The history already has a home:** `git log`, `git blame`, the PR body, and — for
decisions worth carrying forward — `LESSONS.md` and `ROADMAP.md`. None of those go
stale in the reader's face; a comment does.

**Delete on sight:**

- references to a previous implementation, framework, or file that no longer
  exists ("this lived in `app.js`", "ported from the Jinja template", "the comp's
  `data-open-mask`");
- migration or stage markers that have completed ("STAGE 1 of 2", "not yet wired");
- tombstones for deleted code or tests — if the rule still matters, restate it as a
  test; if it does not, let it go;
- dated narration of a past bug whose fix is now plainly visible in the code;
- restatements of what the line below already says.

**Keep** — these are the comments worth writing:

- **why**, when the code cannot say it: a non-obvious constraint, an ordering that
  looks arbitrary but is not, a workaround with the reason it is needed;
- a warning that stops the next reader breaking something ("`_mount_spa` registers
  first, so an entry here shadows the real handler");
- the intent of a guard whose failure message alone would not explain it;
- a legal, domain, or compliance obligation the code satisfies but cannot state.

A past bug may be named **only** where the reader would otherwise "simplify" the
fix away — and then in one sentence, not a paragraph. Rule of thumb: if the comment
would still be true and useful to someone who has never seen the old code, keep it.
Otherwise delete it in the same PR that made it stale.

This applies to code comments, docstrings and test docstrings alike, and it is
retroactive: clean stale narration out of files you are already touching.

## Claude Code — response style

**Short prose, listed results.** Claude's replies are working notes, not an essay.
Say what was done, where it is, and what is next — nothing else. Concretely:

- no preamble, no recap of the request, no summary of the summary;
- prose in short paragraphs; one or two sentences where one or two will do;
- **completed work as a list**, one line per item, with the path or command;
- state caveats once, plainly; do not re-argue a decision already made;
- do not narrate what you are about to do, then do it, then narrate that you did.

Depth belongs in the artefact — the PR body, the commit message, the doc. The chat
reply is the index to it.

## Code style

- Code and comments are **English** — see **Language** above; the only carve-outs
  are domain/legal terms of art, persisted DB slugs, and German UI strings.
- Comments explain the current code, never its history — see **Comments describe
  the code that is there** above.
- Keep `CLAUDE.md` and these standards current when architecture or conventions
  change — update the source in `flowolf86/.github`, not the synced copy.
- Keep `README.md` correct in the same PR as the change it describes — see
  **Documentation (README correctness)** above.
