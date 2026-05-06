import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import busboy from "busboy";
import type { IncomingMessage, ServerResponse } from "node:http";
import { writeFile, mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import QRCode from "qrcode";


const PLUGIN_ID = "buddy-voice";

type TranscriptionProvider = "openclaw" | "elevenlabs" | "openai";

interface PluginConfig {
  routePrefix?: string;
  audioField?: string;
  authToken?: string;
  sessionId?: string;
  framing?: string;
  languageHints?: string[];
  transcriptionProvider?: TranscriptionProvider;
  apiKey?: string;
  model?: string;
}

const DEFAULT_FRAMING = [
  "This message came from Buddy, an iOS app that runs silently in the background and keeps a rolling buffer of the microphone. The user just deliberately pressed a hardware shortcut (Action Button, Back Tap, or a Shortcut) to grab the buffered seconds and ship them to you. The audio was transcribed verbatim and is included below.",
  "",
  "What this means about the user's intent:",
  "• They knew they were being recorded and chose to send this clip — it is not ambient eavesdropping or background context.",
  "• They likely just finished speaking the request out loud and pressed the button immediately after. Treat it as a directive, not a question about transcription.",
  "• They are not in front of their phone screen. Do not ask clarifying questions unless absolutely necessary; default to acting on the most reasonable interpretation.",
  "• They expect the result delivered on their preferred messaging channel (e.g. WhatsApp), not a reply inside the app.",
  "• Do not echo the transcription back to confirm it. They already know what they said.",
  "",
  "Now read the transcription and execute. Be brief in your channel reply — confirm what you did, not what they said.",
].join("\n");

export default definePluginEntry({
  id: PLUGIN_ID,
  name: "Buddy",
  register(api) {
    const config = ((api.pluginConfig as PluginConfig | undefined) ?? {}) as PluginConfig;
    const prefix = (config.routePrefix ?? "/buddy").replace(/\/$/, "");
    const audioField = config.audioField ?? "audio";
    const framing = config.framing ?? DEFAULT_FRAMING;
    const defaultLanguageHints = config.languageHints ?? ["en"];
    const transcriptionProvider: TranscriptionProvider = config.transcriptionProvider ?? "openclaw";
    const isFullActivation = api.registrationMode === "full";

    // First-install bootstrap: write our own enabled:true entry to config so
    // the next gateway restart includes us in startupPluginIds (otherwise the
    // dispatcher's pinned http-route registry never sees our route). Also
    // auto-generate an authToken if the user didn't set one. Both are
    // fire-and-forget so register() stays synchronous per SDK contract.
    //
    // We deliberately DON'T gate this on isFullActivation — first-time
    // install loads in non-full mode (we're not in startupPluginIds yet),
    // and that's exactly when we need to write the entry.
    const generated = config.authToken ? null : randomUUID().replace(/-/g, "");
    if (generated) config.authToken = generated;
    Promise.resolve().then(async () => {
      try {
        await api.runtime.config.mutateConfigFile((cfg: any) => {
          cfg.plugins ??= {};
          cfg.plugins.entries ??= {};
          const entry = cfg.plugins.entries[PLUGIN_ID] ??= {};
          if (entry.enabled !== true) entry.enabled = true;
          entry.config ??= {};
          if (generated && !entry.config.authToken) {
            entry.config.authToken = generated;
          }
        });
        api.logger.info(`Bootstrapped ${PLUGIN_ID} config (enabled + authToken). Restart the gateway to pin HTTP routes.`);
      } catch (err) {
        api.logger.warn(
          "Could not write bootstrap config — user must manually add `plugins.entries.buddy-voice.enabled: true` to ~/.openclaw/openclaw.json",
          err,
        );
      }
    });

    // HTTP route — uses the simple { path, handler } shape per the canonical
    // pattern documented in the OpenClaw plugin SDK.
    api.registerHttpRoute({
      path: `${prefix}/voice`,
      auth: "plugin",
      match: "exact",
      handler: async (req: IncomingMessage, res: ServerResponse) => {
        try {
          await handleVoiceRequest(req, res, {
            api, config, audioField, framing, defaultLanguageHints, transcriptionProvider,
          });
        } catch (err) {
          api.logger.error("Buddy /voice handler crashed", err);
          if (!res.headersSent) {
            sendJson(res, 500, { error: "Internal server error", detail: String(err) });
          }
        }
        return true;
      },
    });

    // Tools — verified canonical shape from voice-call.
    api.registerTool({
      name: "buddy_pair",
      label: "Pair iPhone with Buddy",
      description:
        "Generates a QR code and a buddy:// pairing URL that the user scans with their iPhone Camera to auto-configure the Buddy app's connection to this gateway. Call this when the user asks to set up, pair, or connect their phone.",
      parameters: {
        type: "object",
        properties: {
          endpoint: {
            type: "string",
            description: "Public URL of /buddy/voice (e.g. https://your-host.com/buddy/voice).",
          },
        },
        required: ["endpoint"],
      },
      async execute(_toolCallId: string, params: any) {
        const endpoint: string = String(params?.endpoint ?? "").trim();
        if (!endpoint) {
          return toolText("Need an endpoint URL — pass the public URL of /buddy/voice.");
        }
        const token = config.authToken ?? "";
        const pairURL = `buddy://configure?endpoint=${encodeURIComponent(endpoint)}&token=${encodeURIComponent(token)}`;
        const dataUrl = await QRCode.toDataURL(pairURL, { width: 400, margin: 2 });
        const b64 = dataUrl.replace(/^data:image\/png;base64,/, "");
        return {
          content: [
            {
              type: "text",
              text: `**Pair your iPhone**

Point your iPhone Camera at the QR code below. Tap the banner — Buddy will auto-fill its Settings.

Or enter manually in Buddy → Settings:
- **Endpoint:** ${endpoint}
- **Token:** ${token}`,
            },
            {
              type: "image",
              source: { type: "base64", media_type: "image/png", data: b64 },
            },
          ],
          details: {},
        };
      },
    });

    api.registerTool({
      name: "buddy_last_capture",
      label: "Buddy — last capture",
      description:
        "Returns the most recent voice capture this plugin processed. Useful if the user asks 'what did I just say?'.",
      parameters: { type: "object", properties: {}, required: [] },
      async execute(_toolCallId: string, _params: any) {
        if (!lastCapture) {
          return toolText("No captures recorded since the gateway last started.");
        }
        return toolText(`Last capture at ${lastCapture.receivedAt}: "${truncate(lastCapture.text, 240)}"`);
      },
    });

    api.logger.info(`Buddy plugin ready at POST ${prefix}/voice (field "${audioField}")`);
  },
});

let lastCapture: { text: string; receivedAt: string } | null = null;

// MARK: - Request handler

interface HandlerCtx {
  api: any;
  config: PluginConfig;
  audioField: string;
  framing: string;
  defaultLanguageHints: string[];
  transcriptionProvider: TranscriptionProvider;
}

async function handleVoiceRequest(req: IncomingMessage, res: ServerResponse, ctx: HandlerCtx): Promise<void> {
  if (req.method !== "POST") {
    res.statusCode = 405;
    res.setHeader("Allow", "POST");
    res.end("Method Not Allowed");
    return;
  }

  // Bearer auth (when configured)
  if (ctx.config.authToken) {
    const header = (req.headers["authorization"] as string | undefined) ?? "";
    if (header !== `Bearer ${ctx.config.authToken}`) {
      return sendJson(res, 401, { error: "Unauthorized" });
    }
  }

  const headerHints = (req.headers["x-language-hints"] as string | undefined) ?? "";
  const languageHints = headerHints
    ? headerHints.split(",").map((s) => s.trim()).filter(Boolean)
    : ctx.defaultLanguageHints;

  // Parse multipart, capture the audio field
  let audioBuffer: Buffer | null = null;
  let audioMime = "audio/wav";
  let audioFilename = "clip.wav";
  try {
    await new Promise<void>((resolve, reject) => {
      const bb = busboy({ headers: req.headers, limits: { fileSize: 100 * 1024 * 1024 } });
      bb.on("file", (fieldName, stream, info) => {
        if (fieldName !== ctx.audioField) {
          stream.resume();
          return;
        }
        audioMime = info.mimeType || audioMime;
        audioFilename = info.filename || audioFilename;
        const chunks: Buffer[] = [];
        stream.on("data", (chunk: Buffer) => chunks.push(chunk));
        stream.on("end", () => { audioBuffer = Buffer.concat(chunks); });
        stream.on("error", reject);
      });
      bb.on("close", resolve);
      bb.on("error", reject);
      req.pipe(bb);
    });
  } catch (err) {
    ctx.api.logger.error("Multipart parse failed", err);
    return sendJson(res, 400, { error: "Invalid multipart body", detail: String(err) });
  }

  if (!audioBuffer) {
    return sendJson(res, 400, { error: `Missing audio field "${ctx.audioField}"` });
  }

  // Instant ack via outbound adapter — no agent turn triggered
  setImmediate(async () => {
    try {
      const adapter = await ctx.api.runtime.channel.outbound.loadAdapter('whatsapp');
      if (adapter) {
        const cfg = ctx.api.runtime.config.current() as any;
        const to = req.headers['x-sender'] as string || cfg?.channels?.whatsapp?.allowFrom?.[0] || '';
        if (to) await adapter.send({ cfg, to, text: '🎙️' });
      }
    } catch {}
  });

    // Stage to disk for the transcription provider
  let stagedPath: string;
  try {
    const stateDir = await ctx.api.runtime.state.resolveStateDir(PLUGIN_ID);
    await mkdir(stateDir, { recursive: true });
    const ext = inferExtension(audioMime, audioFilename);
    stagedPath = join(stateDir, `clip-${Date.now()}-${randomUUID()}${ext}`);
    await writeFile(stagedPath, audioBuffer);
  } catch (err) {
    ctx.api.logger.error("Failed to stage upload", err);
    return sendJson(res, 500, { error: "Could not stage audio", detail: String(err) });
  }

  let transcription: string;
  try {
    transcription = await transcribe({
      provider: ctx.transcriptionProvider,
      apiKey: ctx.config.apiKey,
      model: ctx.config.model,
      stagedPath,
      audioMime,
      languageHints,
      api: ctx.api,
    });
  } catch (err) {
    ctx.api.logger.error("Transcription failed", err);
    return sendJson(res, 502, { error: "Transcription provider failed", detail: String(err) });
  }
  if (!transcription) {
    return sendJson(res, 422, { error: "Empty transcription" });
  }

  // Dispatch via OpenClaw hooks — the native mechanism for exactly this use case.
  // POST to /hooks/voice with the transcription; the hook template runs the
  // agent turn and delivers the reply to WhatsApp automatically.
  try {
    const cfg = ctx.api.runtime.config.current() as any;
    const hooksToken = cfg?.hooks?.token as string | undefined;
    const hooksPath = (cfg?.hooks?.path as string | undefined) ?? '/hooks';
    const port = process.env.OPENCLAW_GATEWAY_PORT || '18789';
    if (hooksToken) {
      await fetch(`http://127.0.0.1:${port}${hooksPath}/voice`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${hooksToken}`,
        },
        body: JSON.stringify({ transcription }),
      });
    } else {
      ctx.api.logger.warn('Buddy: hooks.token not configured — cannot dispatch to agent');
    }
  } catch (err) {
    ctx.api.logger.warn("Turn injection unavailable; transcription returned to client only.", err);
  }

  lastCapture = { text: transcription, receivedAt: new Date().toISOString() };
  sendJson(res, 200, { transcription });
}

// MARK: - Helpers

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(body));
}

function toolText(text: string) {
  return {
    content: [{ type: "text", text }],
    details: {},
  };
}

function truncate(s: string, max: number): string {
  return s.length <= max ? s : s.slice(0, max - 1) + "…";
}

function inferExtension(mime: string | undefined, filename: string | undefined): string {
  if (filename && filename.includes(".")) {
    return filename.slice(filename.lastIndexOf("."));
  }
  switch (mime) {
    case "audio/wav": case "audio/x-wav": return ".wav";
    case "audio/mpeg": case "audio/mp3": return ".mp3";
    case "audio/mp4": case "audio/m4a": case "audio/x-m4a": return ".m4a";
    case "audio/webm": return ".webm";
    case "audio/ogg": return ".ogg";
    case "audio/flac": return ".flac";
    default: return ".audio";
  }
}

// MARK: - Transcription dispatch

interface TranscribeArgs {
  provider: TranscriptionProvider;
  apiKey?: string;
  model?: string;
  stagedPath: string;
  audioMime: string;
  languageHints: string[];
  api: any;
}

async function transcribe(args: TranscribeArgs): Promise<string> {
  switch (args.provider) {
    case "openclaw": return transcribeViaOpenclaw(args);
    case "elevenlabs": return transcribeViaElevenLabs(args);
    case "openai": return transcribeViaOpenAI(args);
  }
}

async function transcribeViaOpenclaw(args: TranscribeArgs): Promise<string> {
  const result = await args.api.runtime.mediaUnderstanding.transcribeAudioFile({
    filePath: args.stagedPath,
    mime: args.audioMime,
    languageHints: args.languageHints,
  });
  const text = (result?.text ?? "").trim();
  if (!text) throw new Error("openclaw STT returned empty text");
  return text;
}

async function transcribeViaElevenLabs(args: TranscribeArgs): Promise<string> {
  if (!args.apiKey) throw new Error("ElevenLabs requires `apiKey` in plugin config");
  const buf = await readFile(args.stagedPath);
  const blob = new Blob([buf], { type: args.audioMime });
  const form = new FormData();
  form.append("model_id", args.model ?? "scribe_v1");
  form.append("diarize", "false");
  form.append("tag_audio_events", "false");
  form.append("file", blob, "clip");
  const res = await fetch("https://api.elevenlabs.io/v1/speech-to-text", {
    method: "POST",
    headers: { "xi-api-key": args.apiKey },
    body: form,
  });
  if (!res.ok) throw new Error(`ElevenLabs HTTP ${res.status}: ${await res.text()}`);
  const json = (await res.json()) as { text?: string };
  const text = (json.text ?? "").trim();
  if (!text) throw new Error("ElevenLabs returned empty text");
  return text;
}

async function transcribeViaOpenAI(args: TranscribeArgs): Promise<string> {
  if (!args.apiKey) throw new Error("OpenAI requires `apiKey` in plugin config");
  const buf = await readFile(args.stagedPath);
  const blob = new Blob([buf], { type: args.audioMime });
  const form = new FormData();
  form.append("model", args.model ?? "gpt-4o-transcribe");
  form.append("response_format", "json");
  if (args.languageHints.length > 0) {
    form.append(
      "prompt",
      `The speaker may switch between these languages: ${args.languageHints.join(", ")}. Transcribe each word in its native script.`,
    );
  }
  form.append("file", blob, "clip");
  const res = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: { Authorization: `Bearer ${args.apiKey}` },
    body: form,
  });
  if (!res.ok) throw new Error(`OpenAI HTTP ${res.status}: ${await res.text()}`);
  const json = (await res.json()) as { text?: string };
  const text = (json.text ?? "").trim();
  if (!text) throw new Error("OpenAI returned empty text");
  return text;
}
