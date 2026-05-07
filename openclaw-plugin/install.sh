#!/usr/bin/env bash
# Installs the Buddy plugin into a local OpenClaw instance.
# Run from the plugin directory:
#   ./install.sh

set -euo pipefail
cd "$(dirname "$0")"

if ! command -v openclaw >/dev/null 2>&1; then
  echo "✗ openclaw CLI not found. Install OpenClaw first." >&2; exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "✗ Node.js not found. Install Node 20+." >&2; exit 1
fi

echo "→ Building..."
npm install --include=dev --silent
npm run build --silent

echo "→ Installing plugin..."
openclaw plugins install -l "$(pwd)"

# --- Config ---
echo
DEFAULT_TOKEN=$(node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")
read -rp "Bearer token for iOS app [auto-generated]: " AUTH_TOKEN
AUTH_TOKEN="${AUTH_TOKEN:-$DEFAULT_TOKEN}"

echo
echo "Transcription provider:"
echo "  1) elevenlabs (recommended)"
echo "  2) openai"
read -rp "Choose [1-2, default 1]: " P
case "${P:-1}" in
  2) PROVIDER="openai" ;;
  *) PROVIDER="elevenlabs" ;;
esac
read -rsp "$PROVIDER API key: " API_KEY; echo

# --- Write plugin config ---
echo "→ Writing config..."
openclaw config set plugins.enabled true
openclaw config set plugins.entries.buddy-voice.enabled true
openclaw config set plugins.entries.buddy-voice.config.authToken "$AUTH_TOKEN"
openclaw config set plugins.entries.buddy-voice.config.transcriptionProvider "$PROVIDER"
openclaw config set plugins.entries.buddy-voice.config.apiKey "$API_KEY"

# --- Write hooks config (enables /hooks/agent dispatch to main agent) ---
HOOKS_TOKEN=$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")
openclaw config set hooks.enabled true
openclaw config set hooks.path /hooks
openclaw config set hooks.token "$HOOKS_TOKEN"
openclaw config set hooks.defaultSessionKey agent:main

echo "→ Restarting gateway..."
openclaw gateway restart || echo "  (run 'openclaw gateway restart' manually)"

# --- Pairing URL ---
HOST="${OPENCLAW_PUBLIC_HOST:-}"
if [[ -z "$HOST" ]]; then
  read -rp "Public URL of your OpenClaw gateway (e.g. https://yourdomain.com): " HOST
fi
HOST="${HOST%/}"
ENDPOINT="$HOST/buddy/voice"
ENCODED_ENDPOINT=$(node -e "console.log(encodeURIComponent('$ENDPOINT'))")
ENCODED_TOKEN=$(node -e "console.log(encodeURIComponent('$AUTH_TOKEN'))")
PAIR_URL="buddy://configure?endpoint=${ENCODED_ENDPOINT}&token=${ENCODED_TOKEN}"

echo
echo "✓ Done! Plugin live at POST $ENDPOINT"
echo
echo "Pair your iPhone — scan this URL with the Camera app:"
echo "  $PAIR_URL"
echo "Or paste endpoint + token manually in Buddy → Settings."
