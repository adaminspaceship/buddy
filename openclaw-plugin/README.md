# @adaminspaceship/buddy

OpenClaw plugin that receives audio from the [Buddy iOS app](../) and dispatches the transcribed text to the active agent. Handles ingest → STT → agent injection. The iOS app stays minimal — it just POSTs the audio.

## Install (one command)

```bash
openclaw plugins install adaminspaceship/openclaw-buddy
```

Then configure the bearer token + transcription provider:

```bash
openclaw plugins configure buddy
```

That walks you through the `configSchema` declared in `openclaw.plugin.json` — bearer token, transcription provider (openclaw / elevenlabs / openai), API key if BYOK, language hints. No JSON editing.

Restart the gateway and you're done:

```bash
openclaw gateway restart
```

The plugin is now live at `POST /buddy/voice` on your gateway. Pair your iPhone by either pasting the URL into Buddy → Settings, or by scanning a QR code generated from:

```
buddy://configure?endpoint=https%3A%2F%2Fyour-host%2Fbuddy%2Fvoice&token=YOUR_BEARER
```

## Architecture

```
iPhone (Action Button)
   │  POST /buddy/voice  (multipart/form-data, field "audio")
   │  X-Language-Hints: en,he   (per-request hints from the app)
   │  Authorization: Bearer ...
   ▼
OpenClaw Gateway
   │  HTTP route registered by this plugin
   ▼
Transcription   ←── BYOK: openclaw runtime / ElevenLabs / OpenAI
   ▼
api.enqueueNextTurnInjection   →  agent runs its turn
   │
   ▼
api.on("before_prompt_build")  →  prepends a system addendum framing the voice as a deliberate task
```

## Configuration

Schema lives in `openclaw.plugin.json` so `openclaw plugins configure buddy` can drive it interactively. The full list:

| Field | Required | Default | Notes |
|-------|:--------:|---------|-------|
| `authToken` | ✓ | — | Bearer token the iOS app must send |
| `transcriptionProvider` | | `openclaw` | `openclaw` \| `elevenlabs` \| `openai` |
| `apiKey` | conditional | — | Required when provider is `elevenlabs` or `openai` |
| `model` | | provider default | `scribe_v1` (ElevenLabs) or `gpt-4o-transcribe` (OpenAI) |
| `languageHints` | | `["en"]` | ISO 639-1; the iOS app's `X-Language-Hints` header overrides this per request |
| `routePrefix` | | `/buddy` | HTTP path prefix |
| `audioField` | | `audio` | Multipart field name |
| `framing` | | (built-in) | Override the system addendum that frames the voice as a deliberate task |
| `sessionId` | | — | Inject into a specific agent session |

If you'd rather edit the config file by hand, the same shape works:

```json5
{
  plugins: {
    enabled: true,
    allow: ["buddy"],
    entries: {
      buddy: {
        enabled: true,
        config: {
          authToken: "PICK_A_LONG_RANDOM_STRING",
          transcriptionProvider: "elevenlabs",
          apiKey: "sk_...",
          model: "scribe_v1"
        }
      }
    }
  }
}
```

## Verify

```bash
openclaw plugins inspect buddy --runtime --json

curl -X POST https://your-host/buddy/voice \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "X-Language-Hints: en,he" \
  -F "audio=@./test.wav"
```

Expected: `200 OK` with `{ "transcription": "..." }`. The agent's reply is dispatched on its registered channel asynchronously.

## Request / response contract

### Request
- `POST <prefix>/voice`
- `Content-Type: multipart/form-data`
- `Authorization: Bearer <authToken>`
- Optional `X-Language-Hints: en,he,es` — overrides the plugin-level default.
- Body: one form field named `audio`. Any format the configured STT provider accepts (WAV, m4a, mp3, ogg, flac, webm).

### Response
- `200` — `{ "transcription": "..." }`
- `400` — missing/malformed audio
- `401` — bad bearer token
- `422` — empty transcription
- `502` — provider failed (detail in body)
- `500` — agent injection failed

## SDK symbols this plugin uses

| Symbol | Use |
|--------|-----|
| `api.registerHttpRoute` | Exposes `POST <prefix>/voice` |
| `api.registerTool` | Adds `buddy.last_capture_summary` |
| `api.runtime.mediaUnderstanding.transcribeAudioFile` | Runtime-side STT (when provider is `openclaw`) |
| `api.runtime.state.resolveStateDir` | Plugin-scoped writable dir for staged uploads |
| `api.enqueueNextTurnInjection` | Exactly-once durable context injected into the next agent turn |
| `api.on("before_prompt_build", ...)` | System-prompt addendum framing the voice as a deliberate task |
| `api.pluginConfig` | Reads the per-plugin config |
| `api.logger` | Scoped logger |

## Develop locally (without ClawHub)

For iterating on the plugin itself:

```bash
git clone https://github.com/adaminspaceship/buddy
cd buddy/openclaw-plugin
./install.sh         # builds, links, prompts for config, restarts gateway, prints pairing URL
```

`install.sh` uses `openclaw plugins install -l .` so changes to `src/index.ts` show up after `npm run build` + `openclaw plugins reload buddy` (or a gateway restart).

## Publish a new version (maintainers only)

```bash
./publish.sh             # dry run — shows the upload plan, uploads nothing
./publish.sh --real      # actually publishes to ClawHub
```

The script runs `clawhub login` if you're not authenticated, builds, and runs `clawhub package publish .`. Bump `version` in `package.json` first.

## License

MIT
