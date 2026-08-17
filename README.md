# flowolf86/.github

Default community-health files for this account's repositories.

GitHub serves these as the fallback for any repo of mine that does not define its
own equivalent. Shared CI workflows, conventions and operational notes live in a
separate private repo.

| Path | What it is |
|---|---|
| `CONTRIBUTING.md` | Default contribution guide: branch/PR ceremony, squash-only merges, pre-push checks |
| `.github/PULL_REQUEST_TEMPLATE.md` | Default PR template |
| `.github/ISSUE_TEMPLATE/bug.yml` | Bug report form |
| `.github/ISSUE_TEMPLATE/feature.yml` | Feature/change proposal form |
| `githooks/pre-push` | Hook blocking direct pushes to `master`/`main`; override with `git push --no-verify` |
| `githooks/install.sh` | Installs that hook into a clone |
| `CODEOWNERS` | Owner of this repo. Not inherited — GitHub resolves CODEOWNERS per repo |

Defaults apply to a repo only where that repo has no file of the same type. A repo
with any file in its own `.github/ISSUE_TEMPLATE/` uses none of the forms here.

## Installing the hook

```bash
curl -fsSL https://raw.githubusercontent.com/flowolf86/.github/master/githooks/install.sh | bash
```

It copies `pre-push` into the clone's `.githooks/` and points `core.hooksPath`
there. Run it once per clone: `core.hooksPath` is local git config and does not
travel with a fetch or a new clone.
