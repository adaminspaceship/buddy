<div align="center">

<img src="Buddy/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" alt="Buddy" width="160" />

# Buddy

**Always-on voice → AI agent.**
Tap the iPhone Action Button, the last 30 seconds of audio get transcribed on-device and sent to your agent as a task.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-blue)](https://www.apple.com/ios/)
[![ClawHub](https://img.shields.io/badge/ClawHub-%40adaminspaceship%2Fbuddy-purple)](https://clawhub.dev/packages/@adaminspaceship/buddy)

</div>

---

## Why

You wonder something out loud. Walking down the street, in a meeting, mid-conversation. Then you have to open ChatGPT, type, re-explain the whole conversation as context. Buddy turns that whole loop into one Action Button tap — your agent has the transcript before you've put the phone away.

## How it works

1. **Always-on rolling buffer.** `AVAudioEngine` keeps the last 30s of mic audio in memory (configurable: 10s — 3min).
2. **Tap → capture.** The Action Button fires an `AppIntent`, snapshots the buffer to a WAV.
3. **On-device transcription.** Buddy hits ElevenLabs Scribe with **your own API key** — audio never goes to a third party you don't control.
4. **POST to your agent.** The transcript is sent as `{ "message": "<text>" }` to your OpenClaw `/hooks/agent` endpoint (or any JSON webhook).
5. **Agent does its thing.** The reply lands wherever your agent normally sends — WhatsApp, Slack, etc.

```
mic ─► rolling buffer ─► [Action Button] ─► ElevenLabs Scribe ─► your agent webhook
```

## Repo layout

| Path | Purpose |
|------|---------|
| `Buddy/` | iOS app source — SwiftUI, AppIntents, AVFoundation rolling buffer, ElevenLabs client |
| `openclaw-plugin/` | Optional OpenClaw plugin — accepts `{ message }` and dispatches via `/hooks/agent` |
| `project.yml` | XcodeGen config — regenerates `Buddy.xcodeproj` |
| `tools/` | Build helpers (icon generator) |

## Run the iOS app

Requirements: macOS with Xcode 16+, an Apple Developer account (free is fine), an iPhone with an Action Button (iPhone 15 Pro or newer), an [ElevenLabs API key](https://elevenlabs.io/app/settings/api-keys).

```bash
brew install xcodegen
git clone https://github.com/adaminspaceship/buddy.git
cd buddy
xcodegen generate
open Buddy.xcodeproj
```

In Xcode: set your Development Team in *Signing & Capabilities*, then run on a real iPhone (microphone APIs don't work in the simulator).

## Configure

Open the app and tap the gear icon:

| Setting | What it does |
|---------|--------------|
| **Always listening** | Keep the rolling buffer alive in the background. |
| **Buffer length** | How much audio to retain (10s / 30s / 1m / 2m / 3m). |
| **ElevenLabs API key** | Your `xi-api-key`. Audio is transcribed locally with this key. |
| **Languages** | ISO-639-1 hint passed to Scribe. |
| **Agent URL** | Any JSON webhook that accepts `POST` with `{ "message": "<transcript>" }`. |
| **Bearer token** | Sent as `Authorization: Bearer <token>` if your endpoint requires auth. |

Then map the Action Button: *iOS Settings → Action Button → Shortcut → Tell Buddy*.

## Optional: OpenClaw plugin

If you run [OpenClaw](https://openclaw.dev), the bundled plugin accepts the same `{ message }` payload and forwards it through `/hooks/agent` to whatever channel your agent sends on.

```
openclaw plugins install clawhub:@adaminspaceship/buddy
openclaw plugins configure buddy
openclaw gateway restart
```

The plugin source lives in [`openclaw-plugin/`](./openclaw-plugin/). It also accepts legacy multipart audio for older app builds (and will transcribe server-side via OpenClaw's STT or a configured ElevenLabs/OpenAI key).

## Develop

The Xcode project is regenerated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `Buddy.xcodeproj/` is gitignored. Run `xcodegen generate` after changing source files or project settings.

Plugin development:

```bash
cd openclaw-plugin
npm install
npm run watch       # rebuild on save
./publish.sh        # dry-run publish
./publish.sh --real # publish to ClawHub
```

## License

[MIT](LICENSE) © Adam Eliezerov
