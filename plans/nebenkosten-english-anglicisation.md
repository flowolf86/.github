# Plan — nebenkosten-app English anglicisation (Part B of the English-code sweep)

Status: **approved, deferred.** Phase 1 (comments/docstrings → English) is done and
merged (nebenkosten #70). Phases 2-5 below await a Postgres/Docker-capable environment
(the DB-integration suite must run green between phases; it cannot run in the current
dev box). Linked from [`ROADMAP.md`](../ROADMAP.md).

## Context

The [Language convention](../standards/CONVENTIONS.md#language-code-and-comments-are-english)
requires English code and comments. A full audit of all 10 repos found 9 already
compliant; **nebenkosten-app is the only one with substantive German** — its whole
domain model is German. Decision: **full anglicisation, deepest scope** (rename
identifiers, classes, DB column attributes via `mapped_column("slug", …)` pinning,
and dict/template wire keys), keeping persisted slugs German. One
`refactor/english-code` PR (or a small series of phase PRs), **no version bump**.

## Scope boundary

**Anglicise:** class names; function/method/variable names; DB column **attributes**
(pinned, §2); dict/payload **keys** + the templates/forms that read them (§4).
Comments/docstrings were done in Phase 1.

**Keep German (persisted slugs / carve-outs — never change):**
- `__tablename__` values and `ForeignKey("liegenschaft.id")` string refs (table.column).
- Enum/status string **values**: `status "offen"|"finalisiert"`; `umlageschluessel
  "flaeche"|"einheit"|"direkt"`; `Auszahlung.typ "Guthaben-Erstattung"`;
  `Zahlungseingang.typ "Miete"`; `Ablesung.quelle "Selbst|Mieter|Dienstleister"`;
  `Kostenrechnung.umlagefaehig_status "ja|nein|unbekannt"`.
- The 19 Alembic migrations under `app/migrations/versions/` (never edited).
- i18n/locale files + user-facing German template copy.
- `app/messages.py` string **values** (a user-facing German string catalogue = content,
  like i18n); translate only its comments (done in Phase 1). `import_martin_luther.py`
  is one-off German data — leave.
- URL path slugs: `/api/papierkorb/{kind}/…` where `kind` is a table slug —
  `_TRASH_MODELS` keys and `kind == "…"` comparisons stay German (wire contract).
- `app/static/app.js` reads only generic keys (`data.ok/error/validation`) → **no JS change**.

## §1 Model class mapping (`app/schema.py`, 18 models — keep every `__tablename__`)

| German class | → English | tablename (kept) |
|---|---|---|
| Liegenschaft | Property | liegenschaft |
| LiegenschaftShare | PropertyShare | liegenschaft_share |
| Wohneinheit | Unit | wohneinheit |
| Mietverhaeltnis | Tenancy | mietverhaeltnis |
| VorauszahlungPeriode | AdvancePaymentPeriod | vorauszahlung_periode |
| KaltmietePeriode | BaseRentPeriod | kaltmiete_periode |
| GaragePeriode | GarageRentPeriod | garage_periode |
| Auszahlung | Payout | auszahlung |
| Zahlungseingang | IncomingPayment | zahlungseingang |
| Abrechnungsjahr | BillingYear | abrechnungsjahr |
| MietparteienPeriode | RentalPartiesPeriod | mietparteien_periode |
| Kostenposition | CostItem | kostenposition |
| Kostenrechnung | CostInvoice | kostenrechnung |
| KostenrechnungDirekt | CostInvoiceDirect | kostenrechnung_direkt |
| Korrekturbuchung | Adjustment | korrekturbuchung |
| AbrechnungSnapshot | BillingSnapshot | abrechnung_snapshot |
| Zaehler | Meter | zaehler |
| Ablesung | MeterReading | ablesung |

Also rename calc.py's German model/dataclasses (`VzPeriode` → `AdvancePaymentPeriodInput`,
`AbrechnungInput`, `AbrechnungResult`, etc.) — see §5.

## §2 Column-attribute mapping + pinning (no migration)

Rename the Python attribute; pin the physical column via the first positional arg so the
DB is byte-identical:
```python
# BEFORE
jahr: Mapped[int] = mapped_column(Integer, nullable=False)
# AFTER
year: Mapped[int] = mapped_column("jahr", Integer, nullable=False)
```
FK attributes: `liegenschaft_id`→`property_id ("liegenschaft_id")`, `wohneinheit_id`→
`unit_id`, `mietverhaeltnis_id`→`tenancy_id`, `abrechnungsjahr_id`→`billing_year_id`,
`kostenposition_id`→`cost_item_id`, `kostenrechnung_id`→`cost_invoice_id`,
`zaehler_id`→`meter_id`. Data columns: `bezeichnung`→label, `flaeche_qm`→area_sqm,
`gesamtflaeche_qm`→total_area_sqm, `anzahl_einheiten`→unit_count, `strasse`→street,
`hausnummer`→house_number, `plz`→postal_code, `ort`→city, `adresse`→address,
`mieter_name`→tenant_name, `vertragsbeginn/ende`→contract_start/contract_end,
`kaltmiete_cents`→base_rent_cents, `gueltig_von/bis`→valid_from/valid_to,
`betrag_cents`→amount_cents, `grundgebuehr_cents`→base_fee_cents, `datum`→date,
`typ`→**payment_type** (Payout/IncomingPayment) / **meter_type** (Meter) — NOT bare
`type` (shadows builtin); pin `"typ"`, values stay German, `referenz`→reference,
`kommentar`→comment, `zuordnungs_monat`→assignment_month, `jahr`→year,
`mietparteien`→rental_parties, `interne_notiz`→internal_note, `anzahl`→count,
`umlageschluessel`→allocation_key, `umlagefaehig`→allocatable,
`umlagefaehig_status`→allocatable_status,
`leerstand_traegt_grundgebuehr`→vacancy_bears_base_fee, `nur_grundgebuehr`→base_fee_only,
`nur_umlage_aufteilung`→allocation_split_only, `notiz`→note, `gruppe`→group,
`empfaenger`→recipient, `zeitraum_von/bis`→period_from/period_to,
`einheit`→unit_of_measure, `menge_milli`→quantity_milli, `grund`→reason,
`zaehlernummer`→meter_number, `nachkommastellen`→decimal_places, `stand`→reading,
`quelle`→source. `@property wirkungsmonat/wirkungsjahr` + module-level `wirkungsmonat()`
→ effective_month/effective_year (rename all three together).
Already-English (leave): id, created_at, deleted_at, created_by, owner_id, user_id,
role, name, input_hash, engine_version, snapshot_json, delta_cents, granted_at,
finalized_at/by, unlocked_*.
**Critical:** `Index(...)`/`__table_args__` string args and any `text()`/raw-SQL are
**physical column names** → keep German. `ForeignKey("table.id")` → keep German.
`schema.py` has **no** `relationship()` blocks (verified) — but re-check before editing.

## §3 Phased execution (suite green between phases; `filterwarnings=["error"]`, coverage floor 65)

- **Phase 1 — comments/docstrings.** DONE (nebenkosten #70).
- **Phase 2 — model classes + column attributes (§1+§2).** Rename classes + pin-rename
  columns; update all Python references (repositories.py heaviest, routers/*.py, calc.py,
  dashboard.py, validation.py, pdf.py, service.py). Keep `payload["…"]` keys German for
  now via boundary mapping (`Tenancy(tenant_name=payload["mieter_name"], …)`). Gate: full
  pytest + DB-schema-unchanged check (§6).
- **Phase 3 — function/method/variable renames.** ~90+ German defs
  (`create_kostenposition`→`create_cost_item`, `_jahr_dict`→`_year_dict`,
  `list_zahlungseingaenge`→`list_incoming_payments`, `zahlungen_im_jahr`→
  `payments_in_year`, `effective_kaltmiete_cents`→`effective_base_rent_cents`, …) + all
  call sites. Gate: full pytest.
- **Phase 4 — wire keys + templates/forms (§4).** One key at a time across all 4 sites.
  Gate: full pytest + residual-key grep clean.
- **Phase 5 — calc engine (atomic) + test identifiers.** Rename calc.py internal
  identifiers AND its public API (`compute_abrechnung`, input/result field names) TOGETHER
  with `tests/shadow/loader.py`, `tests/test_shadow_regression.py`, fixtures, and every
  calc caller (repositories/pdf/routers) in ONE commit — the DB-free golden master then
  proves cent-parity immediately. Rename the 47 German `test_*` function names + German
  local vars/asserts. Gate: full pytest + full residual-German scan empty.

Ordering rationale: attributes before keys (dict-builders read attributes); calc last and
atomic because the golden master is its guard. Router **filenames** (`kosten.py`,
`stammdaten.py`, `zaehler.py`, `abrechnung.py`, `liegenschaften.py`) may be renamed too —
if so, update `module.py`/router includes in the same commit.

## §4 Wire-key (dict/template/form) strategy — no desync

`repositories.py` dict-builders emit German keys used ~109× across 24 templates and
matched by routers (`if "mietparteien" in payload`). Per key, change ALL of: (1) the
dict-builder key, (2) every Jinja ref (`{{ x.jahr }}`, loops, conditionals), (3) the HTML
form field `name="jahr"`, (4) router/repo `payload["jahr"]` / `"jahr" in payload` — in one
pass, then `grep -rn '\bjahr\b' app/templates app/routers app/repositories.py` clean before
the next key. **Word-boundary caution:** never blind-`sed` `jahr` (matches
`Abrechnungsjahr`, `zahljahr`, `wirkungsjahr`), `stand` (matches "Bestand"), or `anzahl`;
use anchored regex + manual review.

## §5 Correctness safety net

- **Golden master (primary):** `tests/test_shadow_regression.py` reproduces the 2024/2025
  Excel results to the cent, **DB-free** — run after every phase; Phase 5 is atomic so it
  guards the calc rename.
- **DB-schema invariant (Phase 2 must-pass):** capture `{table: sorted(col.name)}` from
  `Base.metadata` (or `inspect(engine)`) before vs after — must be identical, proving the
  pins preserved every physical column. Migrations are frozen, so `alembic upgrade head`
  on the throwaway PG + ORM reflection equality is definitive.

## §6 Verification commands

```
# Full suite (needs the throwaway PG on 127.0.0.1:55432 — CI builds it in Docker):
cd app && python -m pytest
python -m pytest tests/test_shadow_regression.py -q     # golden master, DB-free, every phase
python -m pytest --cov --cov-report=term-missing        # coverage floor 65
python -m compileall -q app                             # CI lint gate (fast, no DB)
# Schema-unchanged proof (Phase 2):
python -m alembic upgrade head
python -c "import schema,sqlalchemy as sa; print({t.name: sorted(c.name for c in t.columns) for t in schema.Base.metadata.sorted_tables})"
# Residual-German scan (exclude carve-outs): umlauts + German roots in app/**/*.py and
# app/templates/**, minus migrations/, locale files, enum values, __tablename__/ForeignKey/
# Index/mapped_column("slug") first-args, and _TRASH_MODELS/kind slugs.
```

## §7 Risks / gotchas

- `typ`→`payment_type`/`meter_type` (never bare `type`). Enum values stay German.
- `Index(...)`/`text()` string args = physical columns → German. `ForeignKey("…")` → German.
- FK-id keys (`mietverhaeltnis_id`, …) are BOTH ORM attributes (Phase 2) and payload/template
  keys (Phase 4) — keep German through Phase 2 via boundary mapping, flip in Phase 4.
- `_TRASH_MODELS` keys + `kind == "…"` comparisons stay German (URL wire contract). A code
  comment already documents this intent.
- calc result attrs are golden-test contract — rename only in the atomic Phase 5 commit.
- `messages.py` mixes user-facing German copy (KEEP) — do not touch its string values.
- Coverage floor 65 + `filterwarnings=error`: a dropped covered branch or new deprecation
  fails CI.

## Delivery + deploy

- **No version bump** (pure refactor) → merging to master does NOT deploy; prod keeps the
  current image. Run the full suite green (locally in a DB-capable env, or via CI) before
  merging; do not force-merge Phases 2-5 unverified.
- **Before any prod deploy:** take a verified `pg_dump -Fc` of the nebenkosten prod DB
  (container `nebenkosten-db`, db/user `nebenkosten`) and confirm it restores — nebenkosten
  is NOT in the labs-infra daily backup set. Deploy via `release.yml`, never ad-hoc SSH.

## Environment blocker (why deferred)

The current dev box has no Postgres, no Docker, no sudo — nebenkosten's DB-integration tests
(the ones Phases 2-5 touch) can't run, and the safety model needs them green between phases.
Resume in a Postgres/Docker-capable environment, or verify via GitHub Actions CI. Also note:
a concurrent session has been doing i18n work in this repo — coordinate to avoid collisions.
