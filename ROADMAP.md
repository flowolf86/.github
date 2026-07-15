# Roadmap

Cross-repo initiatives tracked centrally, since they span the whole `flowolf86` /
wolf-labs family. Per-repo work continues to live in each repo's issues; this file
is for sweeps that touch every repo and need one coordinated view. Check items off
as each repo is done.

## English-only code and comments conversion

**Goal:** bring every existing repo into line with the
[Language convention](./standards/CONVENTIONS.md#language-code-and-comments-are-english)
— all code, comments, identifiers, tests, and log/commit messages in English. The
narrow carve-outs (German UI strings in i18n catalogues, persisted DB slugs/enum
keys, domain/legal terms of art such as `Nebenkosten`/`Impressum`/`Grundsteuer`,
and external API field names) stay as-is.

**Approach per repo:** audit for non-English identifiers/comments (grep for German
tokens and umlauts in `.py`/`.js` outside locale files and templates), convert code
and comments to English, and preserve every carve-out — never rename a stored slug
or translate a locale string. Ship as one `refactor/english-code` PR per repo with
tests green; no version bump (pure refactor). Do the shared packages before the
apps so shared symbols settle first.

### Progress

Shared packages (do first):
- [x] foundation-api-engine — audited clean 2026-07-14 (only a bilingual maintenance splash, already has EN)
- [x] foundation-ui — audited clean 2026-07-14 (i18n.js catalogue + 1 DE test fixture are carve-outs)

Apps:
- [x] beikost-app — audited clean 2026-07-14 (only test comments quoting German UI strings)
- [x] packliste-app — audited clean 2026-07-14 (only test comments quoting German UI strings)
- [x] scuba-app — audited clean 2026-07-14 (one optional e2e stress-string value)
- [x] gs-app — audited clean 2026-07-14 (`Motorrad` = BMW brand / CarData API carve-out)
- [ ] nebenkosten-app — in progress. Phase 1 (all German code comments/docstrings → English)
  done 2026-07-14 (comments-only, AST-verified, nebenkosten #70). Phases 2-5
  (class/column/function/wire-key/template/test renames) **deferred** pending a
  Postgres/Docker-capable environment — the DB-integration suite can't run in the current
  dev env, and the safety model requires it green between phases. Deploy needs a verified
  prod pg_dump first (nebenkosten is not in the daily backup set).
  **Detailed execution plan:** [`plans/nebenkosten-english-anglicisation.md`](./plans/nebenkosten-english-anglicisation.md)
  (full model/column mapping, phased steps, verification).
- [x] dashboard-app — audited clean 2026-07-14 (registry/admin German UI assertions are content)

Infra / governance:
- [x] labs-infra — audited clean 2026-07-14
- [x] dot-github (this repo) — audited clean 2026-07-14 (one DE error-string quoted as an example in LESSONS)

**Not in scope:** German user-facing copy (locale files, template strings),
persisted German DB slugs/enum keys, domain/legal terms of art, and third-party API
field names — all explicitly preserved per the convention.
