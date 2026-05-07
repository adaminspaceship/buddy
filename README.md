# Buddy

Always-on voice → AI agent. iOS app keeps a rolling buffer of the last 30 seconds of audio (configurable). Press the Action Button → the clip is transcribed on-device via ElevenLabs Scribe (BYOK) → only the transcript text is POSTed to your agent's webhook.

## Repo layout

| Path | Purpose |
|------|---------|
| `Buddy/` | iOS app source (SwiftUI + AppIntents + AVFoundation rolling buffer + ElevenLabs Scribe transcription) |
| `project.yml` | XcodeGen config — regenerates `Buddy.xcodeproj` |
| `tools/generate-icon.swift` | App-icon generator (PNG via CoreGraphics) |

## Run the iOS app

```bash
brew install xcodegen
cd /path/to/buddy
xcodegen generate
open Buddy.xcodeproj
```

In Xcode: set your Development Team in Signing & Capabilities → run on a real iPhone.

## Configure

Buddy → Settings:

- **ElevenLabs API key** — get one at [elevenlabs.io/app/settings/api-keys](https://elevenlabs.io/app/settings/api-keys). Audio is transcribed on-device with this key; only the resulting text leaves the phone.
- **Agent URL** — the webhook on your agent that accepts `POST` with `Content-Type: application/json` and body `{"transcription": "..."}`.
- **Bearer token** *(optional)* — sent as `Authorization: Bearer <token>` if your endpoint requires auth.
- **Languages** — ISO-639-1 hint passed to Scribe (`language_code`).

## License

MIT
