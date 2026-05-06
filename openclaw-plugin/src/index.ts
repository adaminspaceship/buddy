import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { writeFile, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import qrcode from "qrcode-terminal";

const PLUGIN_ID = "buddy-voice";

type TranscriptionProvider = "openclaw" | "elevenlabs" | "openai";

interface PluginConfig {
  /** HTTP path prefix served by this plugin. Defaults to `/buddy`. */
  routePrefix?: string;
  /**
   * The form-data field name the iOS app uses for the audio attachment.
   * The Buddy app sends `audio`.
   */
  audioField?: string;
  /**
   * Optional bearer token. If set, requests must carry
   * `Authorization: Bearer <token>`. Leave unset for open local proxies.
   */
  authToken?: string;
  /**
   * Session id to inject the transcription into. Falls back to whatever
   * the runtime treats as the active session if omitted.
   */
  sessionId?: string;
  /**
   * Prompt prefix wrapped around the transcription before it reaches the
   * agent. Frames the inbound voice as a directive vs. background context.
   */
  framing?: string;
  /**
   * Default language hints. Per-request hints in the `X-Language-Hints`
   * header (sent by the Buddy iOS app) override these.
   */
  languageHints?: string[];
  /**
   * BYOK: which provider transcribes the audio.
   * - `openclaw` (default) — use whichever STT provider is registered with
   *   the OpenClaw runtime.
   * - `elevenlabs` — call ElevenLabs Scribe directly with `apiKey`.
   * - `openai` — call OpenAI gpt-4o-transcribe directly with `apiKey`.
   */
  transcriptionProvider?: TranscriptionProvider;
  /** API key for the chosen BYOK provider. Required when not `openclaw`. */
  apiKey?: string;
  /** Override the model id (e.g. `whisper-1`, `gpt-4o-transcribe`, `scribe_v1`). */
  model?: string;
}

const DEFAULT_FRAMING = [
  "This message came from Audio Dashcam, an iOS app that runs silently in the background and keeps a rolling 30-second buffer of the microphone. The user just deliberately pressed a hardware shortcut (Action Button, Back Tap, or a Shortcuts trigger) to grab the last 30 seconds and ship it to you. The audio was transcribed verbatim and is included below.",
  "",
  "What this means about the user's intent:",
  "• They knew they were being recorded and chose to send this clip — it is not ambient eavesdropping or background context.",
  "• They likely just finished speaking the request out loud and pressed the button immediately after. Treat it as a directive, not a question about transcription.",
  "• They are not in front of their phone screen. Do not ask clarifying questions unless absolutely necessary; default to acting on the most reasonable interpretation. If a small assumption gets the task done, make it.",
  "• They expect the result delivered on their preferred messaging channel (e.g. WhatsApp), not a reply inside the app.",
  "• Do not echo the transcription back to confirm it. They already know what they said.",
  "",
  "Now read the transcription and execute. Be brief in your channel reply — confirm what you did, not what they said.",
].join("\n");

export default definePluginEntry({
  id: PLUGIN_ID,
  name: "Audio Dashcam",
  register(api) {
    if (api.registrationMode !== "full") return;

    const config = ((api.pluginConfig as PluginConfig | undefined) ?? {}) as PluginConfig;
    const prefix = (config.routePrefix ?? "/buddy").replace(/\/$/, "");
    const audioField = config.audioField ?? "audio";
    const framing = config.framing ?? DEFAULT_FRAMING;
    const defaultLanguageHints = config.languageHints ?? ["en"];
    const transcriptionProvider: TranscriptionProvider = config.transcriptionProvider ?? "openclaw";

    // Auto-generate a bearer token on first install if the user didn't set one.
    // Sync set so the rest of register() and tool calls see it immediately;
    // fire-and-forget persistence so SDK's "register must be synchronous"
    // contract is preserved.
    if (!config.authToken) {
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

    api.registerHttpRoute({
      id: `${PLUGIN_ID}.voice`,
      method: "POST",
      path: `${prefix}/voice`,
      description:
        "Receives an audio clip from the Audio Dashcam iOS app, transcribes it, and queues the transcription as the next agent turn.",
      handler: async (req: Request) => {
        if (config.authToken) {
          const header = req.headers.get("authorization") ?? "";
          if (header !== `Bearer ${config.authToken}`) {
            return jsonResponse(401, { error: "Unauthorized" });
          }
        }

        let form: FormData;
        try {
          form = await req.formData();
        } catch (err) {
          return jsonResponse(400, {
            error: "Expected multipart/form-data body",
            detail: String(err),
          });
        }

        const file = form.get(audioField);
        if (!file || typeof file === "string") {
          return jsonResponse(400, {
            error: `Missing audio file field "${audioField}"`,
          });
        }

        // The runtime's media-understanding APIs operate on file paths, so
        // stage the upload to a state directory before transcribing.
        let stagedPath: string;
        try {
          const stateDir = await api.runtime.state.resolveStateDir(PLUGIN_ID);
          await mkdir(stateDir, { recursive: true });
          const blob = file as Blob;
          const buf = Buffer.from(await blob.arrayBuffer());
          const ext = inferExtension(blob.type, (file as any).name);
          stagedPath = join(stateDir, `clip-${Date.now()}-${randomUUID()}${ext}`);
          await writeFile(stagedPath, buf);
        } catch (err) {
          api.logger.error("Failed to stage upload", err);
          return jsonResponse(500, { error: "Could not stage audio", detail: String(err) });
        }

        // Per-request language hints (from the iOS app's X-Language-Hints
        // header) win over the plugin-config default.
        const headerHints = req.headers.get("x-language-hints");
        const languageHints = headerHints
          ? headerHints.split(",").map((s) => s.trim()).filter(Boolean)
          : defaultLanguageHints;

        let transcription: string;
        try {
          transcription = await transcribe({
            provider: transcriptionProvider,
            apiKey: config.apiKey,
            model: config.model,
            stagedPath,
            audioMime: (file as Blob).type || "audio/wav",
            languageHints,
            api,
          });
        } catch (err) {
          api.logger.error("Transcription failed", err);
          return jsonResponse(502, {
            error: "Transcription provider failed",
            detail: String(err),
          });
        }

        if (!transcription) {
          return jsonResponse(422, { error: "Empty transcription" });
        }

        // Hand the transcript to the agent's next turn. enqueueNextTurnInjection
        // is the runtime's documented "exactly-once durable context injection"
        // primitive — perfect for "user just spoke, act on it".
        try {
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
        } catch (err) {
          api.logger.error("Turn injection failed", err);
          return jsonResponse(500, {
            error: "Failed to dispatch to agent",
            detail: String(err),
            transcription,
          });
        }

        lastCapture = {
          text: transcription,
          receivedAt: new Date().toISOString(),
        };

        return jsonResponse(200, { transcription });
      },
    });

    // Reinforce the framing at the system-prompt layer whenever the upcoming
    // turn carries our voice-capture metadata. Without this, the framing only
    // appears as user-turn content, which the model can underweight relative
    // to the system prompt.
    api.on("before_prompt_build", (event: any) => {
      const meta = (event?.injection?.metadata ?? event?.metadata ?? {}) as Record<string, unknown>;
      if (meta.source !== PLUGIN_ID || meta.kind !== "voice-capture") return;
      const note =
        "[Audio Dashcam context] The next user turn was captured by an iOS app's rolling 30-second microphone buffer and submitted via a hardware shortcut. The user is not at the screen. Treat the transcription as a deliberate task to execute, default to action over clarification, and reply on their preferred messaging channel — do NOT echo the transcription back.";
      // The runtime accepts either a string return or a structured envelope;
      // both shapes are documented as valid contributions for prompt-build hooks.
      return { systemAddendum: note };
    });

    // Pair-by-QR: ask the agent "pair my phone" → it prints an ASCII QR
    // containing buddy://configure?endpoint=...&token=... — point your iPhone
    // Camera at the terminal, tap the banner, Buddy auto-fills its Settings.
    api.registerTool({
      id: `${PLUGIN_ID}.pair`,
      name: "Pair iPhone with Buddy",
      description:
        "Generates a QR code and a buddy:// pairing URL that the user scans with their iPhone Camera to auto-configure the Buddy app's connection to this gateway. Call this when the user asks to set up, pair, or connect their phone.",
      inputSchema: {
        type: "object",
        properties: {
          endpoint: {
            type: "string",
            description:
              "Full URL of the /buddy/voice route as the iPhone reaches it from the public internet, e.g. https://your-host.com/buddy/voice",
          },
        },
        required: ["endpoint"],
      },
      execute: async (input: any) => {
        const endpoint: string = String(input?.endpoint ?? "").trim();
        if (!endpoint) {
          return { text: "Need an endpoint URL — pass the public URL of /buddy/voice (e.g. https://your-host.com/buddy/voice)." };
        }
        const token = config.authToken ?? "";
        const pairURL = `buddy://configure?endpoint=${encodeURIComponent(endpoint)}&token=${encodeURIComponent(token)}`;

        // Try the runtime's built-in QR rendering first — gives a PNG that
        // chat surfaces can render inline. Falls back to ASCII if the helper
        // isn't there or fails.
        let pngAttachment: any = null;
        try {
          const media = api.runtime?.media;
          if (media?.renderQr || media?.qr) {
            const renderer = media.renderQr ?? media.qr;
            const result = await renderer.call(media, { text: pairURL, format: "png", size: 320 });
            if (result?.bytes || result?.data) {
              pngAttachment = {
                mimeType: "image/png",
                bytes: result.bytes ?? result.data,
                name: "buddy-pair.png",
              };
            }
          }
        } catch (err) {
          api.logger.warn("Inline QR rendering unavailable, falling back to ASCII", err);
        }

        const qrAscii = await new Promise<string>((resolve) => {
          qrcode.generate(pairURL, { small: true }, resolve);
        });

        const text =
          "**Pair your iPhone**\n\n" +
          "Open the Camera app and point it at the QR below. Tap the banner — Buddy will auto-fill its Settings.\n\n" +
          "```\n" + qrAscii + "```\n" +
          "If the QR doesn't scan in this view, paste this into Buddy → Settings instead:\n\n" +
          "```\n" + pairURL + "\n```\n";

        return pngAttachment
          ? { text, attachments: [pngAttachment] }
          : { text };
      },
    });

    // Optional: a tool the agent can call to recall what was just heard.
    api.registerTool({
      id: `${PLUGIN_ID}.last_capture_summary`,
      name: "Audio Dashcam — last capture",
      description:
        "Returns the most recent voice capture this plugin processed. Useful if the user asks 'what did I just say?' or 'replay that'.",
      inputSchema: {
        type: "object",
        properties: {},
        required: [],
      },
      execute: async () => {
        if (!lastCapture) {
          return { text: "No captures recorded since the gateway last started." };
        }
        return {
          text: `Last capture at ${lastCapture.receivedAt}: "${truncate(lastCapture.text, 240)}"`,
        };
      },
    });

    api.logger.info(
      `Audio Dashcam plugin ready at POST ${prefix}/voice (field "${audioField}")`,
    );
  },
});

let lastCapture: { text: string; receivedAt: string } | null = null;

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function truncate(s: string, max: number): string {
  return s.length <= max ? s : s.slice(0, max - 1) + "…";
}

// MARK: - Transcription dispatch (BYOK)

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
    case "openclaw":
      return transcribeViaOpenclaw(args);
    case "elevenlabs":
      return transcribeViaElevenLabs(args);
    case "openai":
      return transcribeViaOpenAI(args);
  }
}

async function transcribeViaOpenclaw(args: TranscribeArgs): Promise<string> {
  const result = await args.api.runtime.mediaUnderstanding.transcribeAudioFile({
    path: args.stagedPath,
    languageHints: args.languageHints,
  });
  const text = (result?.text ?? "").trim();
  if (!text) throw new Error("openclaw STT returned empty text");
  return text;
}

async function transcribeViaElevenLabs(args: TranscribeArgs): Promise<string> {
  if (!args.apiKey) throw new Error("ElevenLabs requires `apiKey` in plugin config");
  const { readFile } = await import("node:fs/promises");
  const buf = await readFile(args.stagedPath);
  const blob = new Blob([buf], { type: args.audioMime });
  const form = new FormData();
  form.append("model_id", args.model ?? "scribe_v1");
  form.append("diarize", "false");
  form.append("tag_audio_events", "false");
  // No language_code — let Scribe auto-detect for code-switching.
  form.append("file", blob, "clip");

  const res = await fetch("https://api.elevenlabs.io/v1/speech-to-text", {
    method: "POST",
    headers: { "xi-api-key": args.apiKey },
    body: form,
  });
  if (!res.ok) {
    throw new Error(`ElevenLabs HTTP ${res.status}: ${await res.text()}`);
  }
  const json = (await res.json()) as { text?: string };
  const text = (json.text ?? "").trim();
  if (!text) throw new Error("ElevenLabs returned empty text");
  return text;
}

async function transcribeViaOpenAI(args: TranscribeArgs): Promise<string> {
  if (!args.apiKey) throw new Error("OpenAI requires `apiKey` in plugin config");
  const { readFile } = await import("node:fs/promises");
  const buf = await readFile(args.stagedPath);
  const blob = new Blob([buf], { type: args.audioMime });
  const form = new FormData();
  form.append("model", args.model ?? "gpt-4o-transcribe");
  form.append("response_format", "json");
  if (args.languageHints.length > 0) {
    form.append(
      "prompt",
      `The speaker may switch between these languages: ${args.languageHints.join(", ")}. Transcribe each word in its own native script.`,
    );
  }
  form.append("file", blob, "clip");

  const res = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: { Authorization: `Bearer ${args.apiKey}` },
    body: form,
  });
  if (!res.ok) {
    throw new Error(`OpenAI HTTP ${res.status}: ${await res.text()}`);
  }
  const json = (await res.json()) as { text?: string };
  const text = (json.text ?? "").trim();
  if (!text) throw new Error("OpenAI returned empty text");
  return text;
}

// MARK: - Helpers

function inferExtension(mime: string | undefined, filename: string | undefined): string {
  if (filename && filename.includes(".")) {
    return filename.slice(filename.lastIndexOf("."));
  }
  switch (mime) {
    case "audio/wav":
    case "audio/x-wav":
      return ".wav";
    case "audio/mpeg":
    case "audio/mp3":
      return ".mp3";
    case "audio/mp4":
    case "audio/m4a":
    case "audio/x-m4a":
      return ".m4a";
    case "audio/webm":
      return ".webm";
    case "audio/ogg":
      return ".ogg";
    case "audio/flac":
      return ".flac";
    default:
      return ".audio";
  }
}
