# Contributing

Default contribution guide for all `flowolf86` repos. Repo-specific detail lives
in each repo's own `README.md` and `CLAUDE.md`; the full working rules are synced
into each repo at `.standards/CONVENTIONS.md` and `.standards/LESSONS.md`.

## Workflow

**Branch → implement (+ tests) → version bump if user-facing → rebase → run tests locally (green) → PR → CI green → squash merge → release**

- Never commit on or push directly to `master`. Always work on a branch and open
  a PR. Branch names describe the work, not the tool: `feature/`, `bugfix/`,
  `hotfix/`, `chore/`, `refactor/`.
- **Run the full test suite locally and make it green before you push.** CI is
  never the first test run.
- Rebase on `origin/master` before opening: `git fetch origin && git rebase origin/master`.
- Ask before opening the PR.
- **Squash-only merges:** `gh pr merge --squash --delete-branch`. `--merge` and
  `--rebase` are not used.

## Enforcement

Squash-only and no-direct-push are enforced server-side by a repository ruleset
where the plan allows it, and by a client-side `pre-push` hook everywhere.
Install the hook once per clone:

```bash
curl -fsSL https://raw.githubusercontent.com/flowolf86/.github/master/githooks/install.sh | bash
# or, from a checkout of this repo:  ./githooks/install.sh /path/to/your/clone
```

`core.hooksPath` is local git config, so re-run it after a fresh clone.

## Before you push

- Tests pass locally.
- No secrets staged (`.env`, `*.key`, `acme.json` are git-ignored — keep it so).
- For user-facing app changes, the version in `app/pyproject.toml` is bumped.
- `README.md` is still correct for anything the change touches — commands, paths,
  env vars, features, structure. Documentation is corrected in the same PR as the
  change that outdated it, not afterwards.
