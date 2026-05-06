# Buddy

Always-on voice → AI agent. iOS app keeps a rolling buffer of the last 30 seconds of audio (configurable). Press the Action Button → the clip flies to your OpenClaw agent → transcription + task delivery happens server-side. Reply lands on whatever channel your agent uses (WhatsApp, Slack, etc.).

## Repo layout

| Path | Purpose |
|------|---------|
| `Buddy/` | iOS app source (SwiftUI + AppIntents + AVFoundation rolling buffer + background `URLSessionUploadTask`) |
| `openclaw-plugin/` | OpenClaw plugin: HTTP route + STT (BYOK) + agent injection |
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

## Install the plugin into your OpenClaw

```bash
openclaw plugins install clawhub:@adaminspaceship/openclaw-buddy
openclaw plugins configure buddy
openclaw gateway restart
```

Then point the iOS app at the plugin: Buddy → Settings → URL = `https://<your-host>/buddy/voice`. Or scan a QR from `buddy://configure?endpoint=<urlencoded>&token=<bearer>` for instant setup.

See [`openclaw-plugin/README.md`](./openclaw-plugin/README.md) for plugin internals.

## License

MIT
