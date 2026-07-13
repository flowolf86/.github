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
- [ ] foundation-api-engine
- [ ] foundation-ui

Apps:
- [ ] beikost-app
- [ ] packliste-app
- [ ] scuba-app
- [ ] gs-app
- [ ] nebenkosten-app
- [ ] dashboard-app

Infra / governance:
- [ ] labs-infra
- [ ] dot-github (this repo)

**Not in scope:** German user-facing copy (locale files, template strings),
persisted German DB slugs/enum keys, domain/legal terms of art, and third-party API
field names — all explicitly preserved per the convention.
