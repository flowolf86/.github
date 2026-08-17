# flowolf86/.github

Default community-health files for this account's repositories.

GitHub serves the files in this repo as the fallback for any repo of mine that
doesn't define its own — the contribution guide, the pull-request template and
the issue forms — plus the shared `pre-push` hook that keeps `master` PR-only on
every plan.

That is the whole purpose of this repo. It is public because it has to be: GitHub
will not inherit default health files from a private repository. Everything else
— shared CI workflows, conventions, and operational notes — lives in a private
repo instead.

| Path | What it is |
|---|---|
| `CONTRIBUTING.md` | Default contribution guide |
| `.github/PULL_REQUEST_TEMPLATE.md` | Default PR template |
| `.github/ISSUE_TEMPLATE/` | Bug and feature issue forms |
| `githooks/` | `pre-push` hook blocking direct pushes to `master`, and its installer |
| `CODEOWNERS` | Owner of this repo (not inherited — GitHub resolves CODEOWNERS per repo) |

## Installing the hook

```bash
curl -fsSL https://raw.githubusercontent.com/flowolf86/.github/master/githooks/install.sh | bash
```

Run it once per clone: `core.hooksPath` is local git config and does not travel
with a fetch.
