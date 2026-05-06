#!/usr/bin/env bash
# Installs the Buddy plugin into a local OpenClaw instance.
# Run from the plugin directory:
#   ./install.sh
#
# What it does:
#   1. npm install + tsc build
#   2. openclaw plugins install -l .
#   3. Prompts for the 2-3 config values
#   4. Writes them via `openclaw config set` (or prints a paste-able snippet
#      if your version doesn't have it)
#   5. openclaw plugins enable buddy-voice + gateway restart
#   6. Prints a buddy:// pairing URL you can turn into a QR for your phone

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v openclaw >/dev/null 2>&1; then
  echo "✗ The 'openclaw' CLI isn't on PATH. Install OpenClaw first, then re-run." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "✗ Node.js isn't on PATH. Install Node 20+ and re-run." >&2
  exit 1
fi

echo "→ Building plugin (npm install + tsc)..."
npm install --include=dev --silent
npm run build --silent

echo "→ Linking into OpenClaw..."
openclaw plugins install -l "$(pwd)"

# --- Prompt for config ---
echo
echo "Configure the plugin (press Enter to accept defaults):"
echo

# Auth token: random by default, but let user override.
DEFAULT_TOKEN=$(node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")
read -rp "Bearer token (used by your iPhone) [auto-generated]: " AUTH_TOKEN
AUTH_TOKEN="${AUTH_TOKEN:-$DEFAULT_TOKEN}"

echo
echo "Transcription provider:"
echo "  1) openclaw   — use the STT provider already registered with your runtime"
echo "  2) elevenlabs — Scribe v1 (best for code-switched speech)"
echo "  3) openai     — gpt-4o-transcribe"
read -rp "Choose [1-3, default 1]: " PROVIDER_CHOICE
case "${PROVIDER_CHOICE:-1}" in
  2) PROVIDER="elevenlabs" ;;
  3) PROVIDER="openai" ;;
  *) PROVIDER="openclaw" ;;
esac

API_KEY=""
if [[ "$PROVIDER" != "openclaw" ]]; then
  read -rsp "$PROVIDER API key: " API_KEY
  echo
fi

# --- Apply config ---
echo
echo "→ Writing config..."
APPLIED=0
if openclaw config set --help >/dev/null 2>&1; then
  openclaw config set plugins.enabled true
  openclaw config set plugins.entries.buddy-voice.enabled true
  openclaw config set plugins.entries.buddy-voice.config.authToken "$AUTH_TOKEN"
  openclaw config set plugins.entries.buddy-voice.config.transcriptionProvider "$PROVIDER"
  if [[ -n "$API_KEY" ]]; then
    openclaw config set plugins.entries.buddy-voice.config.apiKey "$API_KEY"
  fi
  APPLIED=1
fi

if [[ "$APPLIED" -eq 0 ]]; then
  echo
  echo "Your OpenClaw CLI doesn't have 'config set' — paste this into your config file:"
  echo
  cat <<JSON
{
  "plugins": {
    "enabled": true,
    
    "entries": {
      "buddy-voice": {
        "enabled": true,
        "config": {
          "authToken": "$AUTH_TOKEN",
          "transcriptionProvider": "$PROVIDER"$([ -n "$API_KEY" ] && echo ",\n          \"apiKey\": \"$API_KEY\"")
        }
      }
    }
  }
}
JSON
  echo
  read -rp "Hit Enter once you've saved the config..." _
fi

# --- Activate ---
echo "→ Enabling..."
openclaw plugins enable buddy-voice || true

echo "→ Restarting gateway..."
openclaw gateway restart || {
  echo "  (couldn't auto-restart — run 'openclaw gateway restart' yourself)"
}

# --- Pairing URL ---
HOST="${OPENCLAW_PUBLIC_HOST:-}"
if [[ -z "$HOST" ]]; then
  read -rp "Public host for your OpenClaw gateway (e.g. https://yourdomain.com): " HOST
fi
HOST="${HOST%/}"
ENDPOINT="$HOST/buddy/voice"

# urlencode via node — no shell-magic dependence.
ENCODED_ENDPOINT=$(node -e "console.log(encodeURIComponent('$ENDPOINT'))")
ENCODED_TOKEN=$(node -e "console.log(encodeURIComponent('$AUTH_TOKEN'))")
PAIR_URL="buddy://configure?endpoint=${ENCODED_ENDPOINT}&token=${ENCODED_TOKEN}"

echo
echo "✓ Plugin live at POST $ENDPOINT"
echo
echo "Pair your iPhone — turn this into a QR code (e.g. https://qrcode.show/$PAIR_URL):"
echo
echo "  $PAIR_URL"
echo
echo "Or open Buddy on the phone and paste the URL + token manually."
