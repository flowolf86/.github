#!/usr/bin/env bash
#
# Install the shared git hooks into a clone by pointing core.hooksPath at a
# tracked `.githooks/` dir inside that repo, then dropping the hooks in.
#
# Usage:
#   ./install.sh [/path/to/clone]      # default: current repo
#
# Run once per clone. Because core.hooksPath is a local git config, it is not
# shared automatically — re-run after a fresh clone. The hook files themselves
# are committed to each repo's .githooks/ so they travel with the code.
set -euo pipefail

TARGET="${1:-$(git rev-parse --show-toplevel)}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$TARGET/.githooks"
cp "$SRC_DIR/pre-push" "$TARGET/.githooks/pre-push"
chmod +x "$TARGET/.githooks/pre-push"

git -C "$TARGET" config core.hooksPath .githooks

echo "Installed shared hooks into $TARGET/.githooks and set core.hooksPath."
echo "Commit .githooks/ so it travels with the repo; each fresh clone re-runs this script."
