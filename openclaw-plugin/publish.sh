#!/usr/bin/env bash
# Publishes Buddy to ClawHub. Run from this directory:
#   ./publish.sh          → dry run
#   ./publish.sh --real   → actually publish
#
# Steps:
#   1. Sanity-checks `clawhub` and `node` are on PATH
#   2. Confirms you're logged in (`clawhub whoami`)
#   3. Builds the plugin
#   4. Runs `clawhub package publish --dry-run` so you can read the upload plan
#   5. With --real, runs the real publish

set -euo pipefail
cd "$(dirname "$0")"

REAL=0
[[ "${1:-}" == "--real" ]] && REAL=1

if ! command -v clawhub >/dev/null 2>&1; then
  echo "✗ The 'clawhub' CLI isn't on PATH." >&2
  echo "  Install via the OpenClaw distribution, then re-run." >&2
  exit 1
fi

if ! clawhub whoami >/dev/null 2>&1; then
  echo "→ Not logged in. Running clawhub login..."
  clawhub login
fi

echo "→ Logged in as: $(clawhub whoami)"
echo "→ Building..."
npm install --silent
npm run build --silent

if [[ "$REAL" -eq 0 ]]; then
  echo "→ Dry run (no upload)..."
  clawhub package publish . --dry-run
  echo
  echo "✓ Dry run passed. To actually publish:"
  echo "    ./publish.sh --real"
else
  echo "→ Publishing for real..."
  clawhub package publish .
  echo
  PKG_NAME=$(node -p "require('./package.json').name")
  PKG_VER=$(node -p "require('./package.json').version")
  echo "✓ Published $PKG_NAME@$PKG_VER"
  echo
  echo "Users can now install with:"
  echo "    openclaw plugins install clawhub:$PKG_NAME"
fi
