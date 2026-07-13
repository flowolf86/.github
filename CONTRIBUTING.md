# Contributing

Default contribution guide for all `flowolf86` repos (served from the
`flowolf86/.github` repo). Repo-specific details live in each repo's `CLAUDE.md`
and `README.md`; the shared working rules are in
[`standards/CONVENTIONS.md`](./standards/CONVENTIONS.md) and
[`standards/LESSONS.md`](./standards/LESSONS.md).

## Workflow

**Branch → implement (+ tests) → version bump if user-facing → rebase → PR → CI green → squash merge → release**

- Never commit on or push directly to `master`. Always work on a branch and open
  a PR.
- **Squash-only merges:** `gh pr merge --squash --delete-branch`.
- Ask before opening the PR.
- Rebase on `origin/master` before opening: `git fetch origin && git rebase origin/master`.
- Wait for CI to go green before merging. If the Actions budget is exhausted, run
  the test suite locally and merge via the UI (CI resumes next month).

## Enforcement

Squash-only and no-direct-push are enforced server-side by a repository ruleset
on paid plans, and by a client-side `pre-push` hook everywhere. Install the hook
once per clone:

```bash
curl -fsSL https://raw.githubusercontent.com/flowolf86/.github/master/githooks/install.sh | bash
# or, from a checkout of this repo:  ./githooks/install.sh /path/to/your/clone
```

## Before you push

- Tests pass locally (`make test` or `pytest -q`).
- No secrets staged (`.env`, `*.key`, `acme.json` are git-ignored — keep it so).
- For user-facing app changes, the version in `app/pyproject.toml` is bumped.
- `README.md` is still correct for anything the change touches — commands, paths,
  env vars, features, structure (see
  [README correctness](./standards/CONVENTIONS.md#documentation-readme-correctness)).
