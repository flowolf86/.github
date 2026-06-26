#!/usr/bin/env bash
#
# Apply the master-branch ruleset + squash-only merge settings to every repo.
#
# Server-side enforcement (rulesets / branch protection) on PRIVATE repos needs
# GitHub Pro or higher. This script is the "Pro hardening" layer: run it while on
# a paid plan. It degrades gracefully — if a repo's plan can't accept rulesets it
# prints a skip and moves on, so the client-side pre-push hook stays the backstop
# and a future downgrade to Free breaks nothing.
#
# Idempotent: updates the ruleset in place if one with the same name exists.
#
# Requires: gh (authenticated), jq.
# Usage:    ./apply-rulesets.sh            # all default repos
#           ./apply-rulesets.sh owner/repo # a single repo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULESET_JSON="$SCRIPT_DIR/app-master.json"
RULESET_NAME="$(jq -r .name "$RULESET_JSON")"

REPOS=(
  flowolf86/beikost-app
  flowolf86/packliste-app
  flowolf86/foundation-api-engine
  flowolf86/labs-infra
)
[ "$#" -gt 0 ] && REPOS=("$@")

apply_one() {
  local repo="$1"
  echo "── $repo"

  # 1) Repository merge settings: squash-only.
  if gh api -X PATCH "repos/$repo" \
        -F allow_squash_merge=true \
        -F allow_merge_commit=false \
        -F allow_rebase_merge=false \
        -F delete_branch_on_merge=true >/dev/null 2>&1; then
    echo "   squash-only merge settings applied"
  else
    echo "   ! could not set merge settings (permissions?) — skipping repo"
    return 0
  fi

  # 2) Branch ruleset (create or update). On a plan without ruleset support for
  #    private repos this returns 403/422 — caught, reported, and skipped.
  local existing_id
  existing_id="$(gh api "repos/$repo/rulesets" 2>/dev/null \
                  | jq -r --arg n "$RULESET_NAME" '.[] | select(.name==$n) | .id' \
                  | head -n1 || true)"

  if [ -n "${existing_id:-}" ]; then
    if gh api -X PUT "repos/$repo/rulesets/$existing_id" --input "$RULESET_JSON" >/dev/null 2>&1; then
      echo "   ruleset '$RULESET_NAME' updated (id $existing_id)"
    else
      echo "   ! ruleset update rejected — likely unsupported on this plan; client-side hook remains the backstop"
    fi
  else
    if gh api -X POST "repos/$repo/rulesets" --input "$RULESET_JSON" >/dev/null 2>&1; then
      echo "   ruleset '$RULESET_NAME' created"
    else
      echo "   ! ruleset create rejected — likely unsupported on this plan (Free private); client-side hook remains the backstop"
    fi
  fi
}

for r in "${REPOS[@]}"; do
  apply_one "$r"
done
echo "Done."
