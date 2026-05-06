import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { registerPluginHttpRoute } from "openclaw/plugin-sdk/webhook-ingress";
import busboy from "busboy";
import { writeFile, mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import qrcode from "qrcode-terminal";
import type { IncomingMessage, ServerResponse } from "node:http";

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

    // Auto-generate a bearer token on first install if the user didn't set one.
    if (isFullActivation && !config.authToken) {
      const generated = randomUUID().replace(/-/g, "");
      config.authToken = generated;
      Promise.resolve().then(async () => {
        try {
          await api.runtime.config.mutateConfigFile((cfg: any) => {
            cfg.plugins ??= {};
            cfg.plugins.entries ??= {};
            cfg.plugins.entries[PLUGIN_ID] ??= {};
            cfg.plugins.entries[PLUGIN_ID].config ??= {};
            if (!cfg.plugins.entries[PLUGIN_ID].config.authToken) {
              cfg.plugins.entries[PLUGIN_ID].config.authToken = generated;
            }
          });
          api.logger.info(`Generated authToken for ${PLUGIN_ID}.`);
        } catch (err) {
          api.logger.warn("Could not persist authToken; using session-only.", err);
        }
      });
    }

    // HTTP route: POST <prefix>/voice — Express-style (req, res), as used by
    // every canonical plugin that exposes inbound HTTP.
    registerPluginHttpRoute({
      auth: "plugin",
      match: "exact",
      path: `${prefix}/voice`,
      pluginId: PLUGIN_ID,
      source: "buddy-voice-ingress",
      log: api.logger,
      handler: async (req, res) => {
        if (req.method !== "POST") {
          return sendJson(res, 405, { error: "Method not allowed" });
        }

        // Bearer auth (when configured)
        if (config.authToken) {
          const header = (req.headers["authorization"] as string | undefined) ?? "";
          if (header !== `Bearer ${config.authToken}`) {
            return sendJson(res, 401, { error: "Unauthorized" });
          }
        }

        const headerHints = (req.headers["x-language-hints"] as string | undefined) ?? "";
        const languageHints = headerHints
          ? headerHints.split(",").map((s) => s.trim()).filter(Boolean)
          : defaultLanguageHints;

        // Parse multipart, capture the audio field
        let audioBuffer: Buffer | null = null;
        let audioMime = "audio/wav";
        let audioFilename = "clip.wav";
        try {
          await new Promise<void>((resolve, reject) => {
            const bb = busboy({ headers: req.headers, limits: { fileSize: 100 * 1024 * 1024 } });
            bb.on("file", (fieldName, stream, info) => {
              if (fieldName !== audioField) {
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
          api.logger.error("Multipart parse failed", err);
          return sendJson(res, 400, { error: "Invalid multipart body", detail: String(err) });
        }

        if (!audioBuffer) {
          return sendJson(res, 400, { error: `Missing audio field "${audioField}"` });
        }

        // Stage to disk for the transcription provider
        let stagedPath: string;
        try {
          const stateDir = await api.runtime.state.resolveStateDir(PLUGIN_ID);
          await mkdir(stateDir, { recursive: true });
          const ext = inferExtension(audioMime, audioFilename);
          stagedPath = join(stateDir, `clip-${Date.now()}-${randomUUID()}${ext}`);
          await writeFile(stagedPath, audioBuffer);
        } catch (err) {
          api.logger.error("Failed to stage upload", err);
          return sendJson(res, 500, { error: "Could not stage audio", detail: String(err) });
        }

        let transcription: string;
        try {
          transcription = await transcribe({
            provider: transcriptionProvider,
            apiKey: config.apiKey,
            model: config.model,
            stagedPath,
            audioMime,
            languageHints,
            api,
          });
        } catch (err) {
          api.logger.error("Transcription failed", err);
          return sendJson(res, 502, { error: "Transcription provider failed", detail: String(err) });
        }
        if (!transcription) {
          return sendJson(res, 422, { error: "Empty transcription" });
        }

        // Best-effort: try to dispatch the transcript into the agent's next
        // turn. If the symbol isn't available on this runtime version, we
        // still return the text to the iOS app so the feature degrades gracefully.
        try {
          if (typeof api.enqueueNextTurnInjection === "function") {
            await api.enqueueNextTurnInjection({
              sessionId: config.sessionId,
              content: `${framing}\n\n---\n${transcription}`,
              metadata: {
                source: PLUGIN_ID,
                kind: "voice-capture",
                transcription,
                receivedAt: new Date().toISOString(),
              },
            });
          }
        } catch (err) {
          api.logger.warn("Turn injection unavailable; transcription returned to client only.", err);
        }

        lastCapture = { text: transcription, receivedAt: new Date().toISOString() };
        sendJson(res, 200, { transcription });
      },
    });

    // Tools — using verified field shape from canonical plugins.
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
        const qrAscii = await new Promise<string>((resolve) => {
          qrcode.generate(pairURL, { small: true }, resolve);
        });
        const text =
          "**Pair your iPhone**\n\n" +
          "Open the Camera app and point it at the QR below. Tap the banner — Buddy will auto-fill its Settings.\n\n" +
          "```\n" + qrAscii + "```\n" +
          "Or paste this URL into Buddy → Settings:\n\n" +
          "```\n" + pairURL + "\n```\n";
        return toolText(text);
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
