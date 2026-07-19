#!/usr/bin/env bash
# dev.sh — one self-healing entrypoint for the local test loop.
#
# Canonical source: flowolf86/.github/standards/dev.sh  (synced to each app as
# .standards/dev.sh). Do not edit the synced copy — change the source.
#
# It neutralises the whole "the suite is CI-only" trap family documented in
# LESSONS.md by making ONE command set the environment up the way CI does:
#   * pins Python 3.12 (host default may be 3.13 -> phantom failures);
#   * editable-installs the vendored foundation / foundation-ui submodules
#     (foundation-ui MUST be -e or its testing/*.js gate assets are dropped);
#   * runs pytest FROM app/ (a repo-root run loads the production .env);
#   * exports DATABASE_URL to a per-app localhost Postgres (the ini default
#     points at the 'pg' container host, unreachable bare-metal);
#   * sends bytecode to a writable PYTHONPYCACHEPREFIX (stale root-owned
#     __pycache__ from Docker builds otherwise runs old bytecode);
#   * pins -c pytest-e2e.ini for e2e (gets the timeout + websockets-ignore;
#     a bare `pytest app/e2e` adopts app/pyproject and kills the server thread);
#   * node --check's the client JS (pytest never loads it; a syntax error there
#     ships green yet breaks the whole UI).
# The one thing it cannot self-heal — root-owned build/egg-info left by a prior
# Docker build — it detects and hands you a sudo one-liner (no passwordless sudo).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

log()  { printf '\033[1;34m[dev]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[dev]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[dev]\033[0m %s\n' "$*" >&2; exit 1; }

VENV=".venv"
PYBIN="$VENV/bin/python"

# --- derive the DB identity + local DSN from the repo's own test config -------
# app/pyproject.toml already declares the canonical DSN as the ini option
# `foundation_test_dsn`; we reuse its user/pass/dbname verbatim and only swap the
# container host:port for a per-app localhost port.
[ -f app/pyproject.toml ] || die "run from an app repo (app/pyproject.toml not found)"
DSN_INI="$(grep -E '^[[:space:]]*foundation_test_dsn' app/pyproject.toml | head -1 | sed -E 's/.*"(.*)".*/\1/')"
[ -n "$DSN_INI" ] || die "foundation_test_dsn not found in app/pyproject.toml"
CREDS="$(printf '%s' "$DSN_INI" | sed -E 's#.*://([^@]*)@.*#\1#')"   # user:pass
DBNAME="$(printf '%s' "$DSN_INI" | sed -E 's#.*/([^/?]+)(\?.*)?$#\1#')"

# Per-app host port. The fleet already uses a fixed map (dashboard 55433, nbk
# 55432, ...); preserve it so we adopt the existing containers rather than
# orphaning them. Unknown apps get a deterministic port outside the reserved
# range; TEST_PG_PORT overrides everything.
# Keyed on the DB name in foundation_test_dsn (note nebenkosten's is 'nbk').
case "$DBNAME" in
  dashboard) PORT=55433 ;;
  nbk)       PORT=55432 ;;
  scuba)     PORT=55434 ;;
  beikost)   PORT=55435 ;;
  packliste) PORT=55436 ;;
  gs)        PORT=55437 ;;
  *)         PORT=$(( 55440 + $(printf '%s' "$DBNAME" | cksum | cut -d' ' -f1) % 500 )) ;;
esac
PORT="${TEST_PG_PORT:-$PORT}"
CONTAINER="${DBNAME}-test-pg"
LOCAL_DSN="postgresql+asyncpg://${CREDS}@localhost:${PORT}/${DBNAME}"
PYCACHE="${TMPDIR:-/tmp}/wl-pycache-${DBNAME}"

port_open() { (exec 3<>"/dev/tcp/localhost/${PORT}") 2>/dev/null; }

# --- guards -------------------------------------------------------------------
check_submodules() {
  # A clone without --recurse-submodules leaves packages/* empty; the editable
  # install then fails cryptically. Detect and hand off the fix.
  for p in packages/foundation packages/foundation-ui; do
    if [ ! -f "$p/pyproject.toml" ]; then
      warn "submodule $p is not populated."
      warn "Run once, then re-run:"
      printf '\n    git submodule update --init --recursive\n\n' >&2
      die "blocked on unpopulated submodules"
    fi
  done
}

check_root_owned_artifacts() {
  # Prior Docker builds can leave root-owned build/ + *.egg-info that block the
  # editable install (`Cannot update time stamp of directory ...egg-info`). We
  # can't rm them (no passwordless sudo) — detect and hand off.
  local me blockers=()
  me="$(id -u)"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$(stat -c '%u' "$d" 2>/dev/null || echo "$me")" != "$me" ]; then
      blockers+=("$d")
    fi
  done < <(find packages app -maxdepth 2 \( -name '*.egg-info' -o -name build \) -type d 2>/dev/null)
  if [ "${#blockers[@]}" -gt 0 ]; then
    warn "Root-owned build artifacts (from a prior Docker build) block the editable install."
    warn "Run this once, then re-run 'dev setup':"
    printf '\n    sudo rm -rf %s\n\n' "${blockers[*]}" >&2
    die "blocked on root-owned artifacts"
  fi
}

# --- subcommands --------------------------------------------------------------
cmd_setup() {
  command -v uv >/dev/null 2>&1 || die "uv not found (https://docs.astral.sh/uv/); install it first"
  check_submodules
  if [ ! -x "$PYBIN" ] || ! "$PYBIN" --version 2>&1 | grep -q '3\.12'; then
    log "creating $VENV pinned to Python 3.12"
    uv venv --python 3.12 "$VENV"
  fi
  check_root_owned_artifacts
  log "editable install (foundation, foundation-ui, app[dev,e2e])"
  VIRTUAL_ENV="$VENV" uv pip install -q \
    -e packages/foundation \
    -e packages/foundation-ui \
    -e "app/[dev]" -e "app/[e2e]"
  "$PYBIN" -c "import foundation, foundation_ui" \
    || die "editable install did not make foundation importable"
  log "ready — venv $($PYBIN --version)"
}

cmd_db() {
  command -v docker >/dev/null 2>&1 || die "docker not found"
  # The port is the source of truth: reuse whatever already serves it (the fleet
  # has pre-existing *-test-pg containers, some under legacy short names) before
  # touching any named container of our own.
  if port_open; then
    log "reusing existing Postgres already listening on :$PORT"
  elif docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker start "$CONTAINER" >/dev/null 2>&1 || true
    log "started container $CONTAINER on :$PORT"
  else
    log "starting $CONTAINER (postgres:16) on :$PORT"
    local user pass
    user="${CREDS%%:*}"; pass="${CREDS#*:}"
    docker run -d --name "$CONTAINER" \
      -e POSTGRES_USER="$user" -e POSTGRES_PASSWORD="$pass" -e POSTGRES_DB="$DBNAME" \
      -p "${PORT}:5432" postgres:16 >/dev/null
  fi
  log "waiting for Postgres on :$PORT"
  for _ in $(seq 1 30); do port_open && { ensure_database; log "Postgres ready"; return 0; }; sleep 1; done
  die "Postgres on :$PORT did not become ready"
}

# A reused container may have been created with a different POSTGRES_DB than this
# app's DSN expects (e.g. a legacy gs-test-pg with db 'gsbasecamp' when the DSN
# wants 'gs'), so tests fail with InvalidCatalogNameError. Create the expected
# database if it's absent; the schema is wiped and migrated fresh regardless.
ensure_database() {
  local cname user
  cname="$(docker ps --filter "publish=${PORT}" --format '{{.Names}}' | head -1)"
  user="${CREDS%%:*}"
  [ -n "$cname" ] || return 0
  docker exec "$cname" psql -U "$user" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='${DBNAME}'" 2>/dev/null | grep -q 1 && return 0
  docker exec "$cname" psql -U "$user" -d postgres -q -c "CREATE DATABASE \"${DBNAME}\"" >/dev/null 2>&1 \
    && log "created database ${DBNAME}" || warn "could not ensure database ${DBNAME} exists on ${cname}"
}

# Deliver a clean database every run — exactly what CI gets from its fresh
# Postgres service. The container is long-lived and reused (so it stays warm and
# start-up is instant), but its *contents* are wiped to empty before each run, so
# the harness always migrates from a known-empty schema. This guards both failure
# modes a reused DB otherwise hits: schema drift (a persisted alembic_version
# pointing at a revision this branch no longer has -> "Can't locate revision") and
# stale-data leakage across runs. The replay cost is negligible (measured: a
# full drop+migrate adds no observable time — suite runtime is dominated by the
# tests). Discovered by published port, so it works for legacy-named containers.
reset_db() {
  local cname user
  cname="$(docker ps --filter "publish=${PORT}" --format '{{.Names}}' | head -1)"
  user="${CREDS%%:*}"
  [ -n "$cname" ] || { warn "no container publishing :$PORT — skipping DB reset"; return 0; }
  docker exec "$cname" psql -U "$user" -d "$DBNAME" -q \
    -c 'DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;' >/dev/null 2>&1 \
    && log "clean database (fresh schema, matching CI)" \
    || warn "could not reset schema on $cname"
}

_ensure_env() { [ -x "$PYBIN" ] && "$PYBIN" -c "import foundation" 2>/dev/null || cmd_setup; }

# $@ passes through to pytest (e.g. --cov=., -k pattern, a nodeid)
_pytest_unit() {
  ( cd app && PYTHONPYCACHEPREFIX="$PYCACHE" DATABASE_URL="$LOCAL_DSN" \
      "../$PYBIN" -m pytest -q "$@" )
}

cmd_test() { _ensure_env; cmd_db; reset_db; log "unit suite (from app/, DB :$PORT)"; _pytest_unit "$@"; }

cmd_e2e() {
  _ensure_env
  cmd_db
  reset_db
  log "installing playwright chromium (idempotent)"
  "$PYBIN" -m playwright install chromium >/dev/null 2>&1 || warn "playwright install skipped"
  log "e2e suite (repo root, -c pytest-e2e.ini, DB :$PORT)"
  PYTHONPYCACHEPREFIX="$PYCACHE" DATABASE_URL="$LOCAL_DSN" \
    "$PYBIN" -m pytest -c pytest-e2e.ini app/e2e "$@"
}

cmd_jscheck() {
  # pytest never loads client JS; a syntax error there (e.g. a smart quote in a
  # locale catalogue) ships green yet breaks the whole UI. Mirror CI's backstop.
  command -v node >/dev/null 2>&1 || { warn "node not found — skipping JS check (CI still runs it)"; return 0; }
  local files=()
  for g in app/static/*.js app/static/locales/*.js; do
    [ -e "$g" ] && files+=("$g")
  done
  [ "${#files[@]}" -gt 0 ] || { log "no client JS to check"; return 0; }
  log "node --check ${#files[@]} client script(s)"
  for f in "${files[@]}"; do node --check "$f"; done
  log "client JS OK"
}

cmd_typecheck() {
  _ensure_env
  log "mypy"
  ( cd app && PYTHONPYCACHEPREFIX="$PYCACHE" "../$PYBIN" -m mypy . )
}

# The full local gate, mirroring CI: unit suite with coverage, JS syntax, types.
cmd_check() {
  _ensure_env; cmd_db; reset_db
  log "unit suite + coverage (from app/, DB :$PORT)"
  _pytest_unit --cov=. --cov-report=term-missing:skip-covered
  cmd_jscheck
  cmd_typecheck
  log "check complete"
}

cmd_clean() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$VENV" "$PYCACHE"
  log "removed $VENV, $PYCACHE, container $CONTAINER"
}

case "${1:-}" in
  setup)     shift; cmd_setup "$@" ;;
  db)        shift; cmd_db "$@" ;;
  test)      shift; cmd_test "$@" ;;
  e2e)       shift; cmd_e2e "$@" ;;
  jscheck)   shift; cmd_jscheck "$@" ;;
  typecheck) shift; cmd_typecheck "$@" ;;
  check)     shift; cmd_check "$@" ;;
  clean)     shift; cmd_clean "$@" ;;
  *) die "usage: dev {setup|db|test|e2e|jscheck|typecheck|check|clean}" ;;
esac
