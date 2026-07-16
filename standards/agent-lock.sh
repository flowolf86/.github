#!/usr/bin/env bash
# agent-lock — advisory PUBLISH lease for concurrent agents sharing one host.
#
# Why this exists
# ---------------
# Multiple agents (Claude sessions, the human, CI-adjacent scripts) operate the
# same ~/Dev repos at once. That produces TWO distinct classes of conflict:
#
#   A. Working-tree / HEAD collisions — a linter reverts your files, HEAD moves
#      mid-command, your branch gets force-pushed with someone else's commit.
#      >>> Fixed by ISOLATION, not by this lock: do every risky git edit in a
#          `git worktree add <tmp> origin/master`. See CONVENTIONS.md.
#
#   B. Publish races — two agents pick the SAME version number, both merge to
#      master, a release tag ends up mislabeled. Worktrees do NOT fix this: the
#      collision is on the shared remote, during the short "choose version →
#      push branch → merge → tag release" critical section.
#      >>> Fixed by THIS lock: serialize that critical section per repo.
#
# Model
# -----
# The lease is an atomic `mkdir` directory (mkdir is the POSIX atomic
# create-or-fail primitive — works across separate processes, unlike a bare
# flock fd which cannot survive across an agent's separate shell invocations).
# Ownership is proven by a random TOKEN printed at acquire time. A lease older
# than its TTL is STALE and may be broken by any acquirer, so an agent that dies
# mid-publish can never deadlock a repo.
#
# Usage
# -----
#   agent-lock acquire <repo> [--ttl S] [--wait S]   # prints TOKEN on stdout (fd1)
#   agent-lock release <repo> <token>
#   agent-lock renew   <repo> <token> [--ttl S]      # extend a long publish
#   agent-lock status  <repo>
#   agent-lock with    <repo> [--ttl S] [--wait S] -- <cmd...>   # acquire→run→release
#
# Typical agent flow (one repo, whole publish under the lease):
#   TOKEN=$(agent-lock acquire beikost-app) || exit 1
#   trap 'agent-lock release beikost-app "$TOKEN"' EXIT
#   # ...bump version, git push, gh pr merge --admin, gh release create...
#
# Env: AGENT_LOCK_DIR (default /tmp/agent-locks), AGENT_ID (label recorded in the
# lease; defaults to user@host). Exit 75 (EX_TEMPFAIL) = lock busy / not acquired.
set -euo pipefail

LOCK_ROOT="${AGENT_LOCK_DIR:-/tmp/agent-locks}"
DEFAULT_TTL=900     # 15 min — comfortably longer than a normal publish
DEFAULT_WAIT=300    # wait up to 5 min for a busy peer before giving up
EX_TEMPFAIL=75

_now()  { date +%s; }
_die()  { echo "agent-lock: $*" >&2; exit 1; }
_busy() { echo "agent-lock: $*" >&2; exit "$EX_TEMPFAIL"; }

_lockdir() {
  local repo="$1"
  [ -n "$repo" ] || _die "repo name required"
  # sanitise to a safe single path segment
  printf '%s/%s.lock' "$LOCK_ROOT" "$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_')"
}

# Is $dir a live lease? echoes "held" / "stale" / "free"
_state() {
  local dir="$1"
  [ -d "$dir" ] || { echo free; return; }
  local exp; exp="$(cat "$dir/expires" 2>/dev/null || echo 0)"
  if [ "$(_now)" -ge "${exp:-0}" ]; then echo stale; else echo held; fi
}

_write_meta() {
  local dir="$1" token="$2" ttl="$3"
  printf '%s\n' "$token" > "$dir/token"
  printf '%s\n' "${AGENT_ID:-$(id -un)@$(hostname -s)}" > "$dir/agent"
  printf '%s\n' "$(_now)" > "$dir/acquired"
  printf '%s\n' "$(( $(_now) + ttl ))" > "$dir/expires"
}

cmd_acquire() {
  local repo="$1"; shift
  local ttl="$DEFAULT_TTL" wait="$DEFAULT_WAIT"
  while [ $# -gt 0 ]; do case "$1" in
    --ttl)  ttl="$2";  shift 2;;
    --wait) wait="$2"; shift 2;;
    *) _die "unknown acquire arg: $1";;
  esac; done
  local dir; dir="$(_lockdir "$repo")"
  mkdir -p "$LOCK_ROOT"
  local deadline=$(( $(_now) + wait ))
  while :; do
    if mkdir "$dir" 2>/dev/null; then
      local token; token="$(_new_token)"
      _write_meta "$dir" "$token" "$ttl"
      printf '%s\n' "$token"          # stdout: the caller captures this
      return 0
    fi
    # couldn't create — someone holds it (or it's stale)
    if [ "$(_state "$dir")" = stale ]; then
      # break a dead agent's lease and retry immediately
      local prev; prev="$(cat "$dir/agent" 2>/dev/null || echo '?')"
      rm -rf "$dir" 2>/dev/null || true
      echo "agent-lock: broke stale lease on '$repo' (was held by $prev)" >&2
      continue
    fi
    [ "$(_now)" -lt "$deadline" ] || _busy "lease on '$repo' busy (held by $(cat "$dir/agent" 2>/dev/null || echo '?'), $(( $(cat "$dir/expires" 2>/dev/null || _now) - $(_now) ))s left); waited ${wait}s"
    sleep 3
  done
}

_new_token() { printf '%s-%s-%s' "$(_now)" "$$" "${RANDOM}${RANDOM}"; }

_check_owner() {
  local dir="$1" token="$2"
  [ -d "$dir" ] || _die "no lease to operate on"
  [ "$(cat "$dir/token" 2>/dev/null)" = "$token" ] || _die "token mismatch — you do not own this lease"
}

cmd_release() {
  local repo="$1" token="${2:-}"
  [ -n "$token" ] || _die "release requires <token>"
  local dir; dir="$(_lockdir "$repo")"
  [ -d "$dir" ] || { echo "agent-lock: '$repo' already free" >&2; return 0; }
  _check_owner "$dir" "$token"
  rm -rf "$dir"
}

cmd_renew() {
  local repo="$1" token="${2:-}"; shift 2 || true
  local ttl="$DEFAULT_TTL"
  while [ $# -gt 0 ]; do case "$1" in --ttl) ttl="$2"; shift 2;; *) _die "unknown renew arg: $1";; esac; done
  [ -n "$token" ] || _die "renew requires <token>"
  local dir; dir="$(_lockdir "$repo")"
  _check_owner "$dir" "$token"
  printf '%s\n' "$(( $(_now) + ttl ))" > "$dir/expires"
  echo "agent-lock: renewed '$repo' for ${ttl}s" >&2
}

cmd_status() {
  local repo="$1"
  local dir; dir="$(_lockdir "$repo")"
  local st; st="$(_state "$dir")"
  case "$st" in
    free)  echo "free";;
    stale) echo "stale (held by $(cat "$dir/agent" 2>/dev/null), expired $(( $(_now) - $(cat "$dir/expires" 2>/dev/null || _now) ))s ago — next acquire breaks it)";;
    held)  echo "held by $(cat "$dir/agent" 2>/dev/null), $(( $(cat "$dir/expires" 2>/dev/null) - $(_now) ))s left";;
  esac
}

cmd_with() {
  local repo="$1"; shift
  local passthru=()
  while [ $# -gt 0 ]; do
    if [ "$1" = "--" ]; then shift; break; fi
    passthru+=("$1"); shift
  done
  [ $# -gt 0 ] || _die "with: missing -- <command>"
  local token; token="$(cmd_acquire "$repo" "${passthru[@]}")" || exit "$EX_TEMPFAIL"
  local rc=0
  "$@" || rc=$?
  cmd_release "$repo" "$token" || true
  return "$rc"
}

sub="${1:-}"; [ -n "$sub" ] || _die "usage: agent-lock {acquire|release|renew|status|with} <repo> [...]"
shift
[ $# -gt 0 ] || _die "repo name required"
case "$sub" in
  acquire) cmd_acquire "$@";;
  release) cmd_release "$@";;
  renew)   cmd_renew "$@";;
  status)  cmd_status "$@";;
  with)    cmd_with "$@";;
  *) _die "unknown subcommand: $sub";;
esac
