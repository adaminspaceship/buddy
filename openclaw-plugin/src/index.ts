import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import busboy from "busboy";
import type { IncomingMessage, ServerResponse } from "node:http";
import { writeFile, mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

const PLUGIN_ID = "buddy-voice";

interface PluginConfig {
  authToken?: string;
  apiKey?: string;
  model?: string;
  transcriptionProvider?: "openclaw" | "elevenlabs" | "openai";
  routePrefix?: string;
  audioField?: string;
}

export default definePluginEntry({
  id: PLUGIN_ID,
  name: "Buddy",
  register(api) {
    const cfg = ((api.pluginConfig as PluginConfig | undefined) ?? {}) as PluginConfig;
    const prefix = (cfg.routePrefix ?? "/buddy").replace(/\/$/, "");
    const audioField = cfg.audioField ?? "audio";
    // Default to openclaw built-in STT, fall back to elevenlabs/openai if configured
    const provider = cfg.transcriptionProvider ?? "openclaw";

    // Auto-bootstrap: on first load, write everything needed into config.
    // This fires on every load (discovery + full) so ClawHub installs work
    // without any manual steps — one gateway restart after install is enough.
    const generated = cfg.authToken ? null : randomUUID().replace(/-/g, "");
    if (generated) cfg.authToken = generated;

    Promise.resolve().then(async () => {
      try {
        await api.runtime.config.mutateConfigFile((c: any) => {
          // Enable the plugin itself
          c.plugins ??= {};
          c.plugins.entries ??= {};
          const e = c.plugins.entries[PLUGIN_ID] ??= {};
          if (e.enabled !== true) e.enabled = true;
          e.config ??= {};
          if (generated && !e.config.authToken) e.config.authToken = generated;

          // Bootstrap hooks so /hooks/agent works out of the box
          if (!c.hooks?.enabled) {
            const hooksToken = randomUUID().replace(/-/g, "") + randomUUID().replace(/-/g, "");
            c.hooks ??= {};
            c.hooks.enabled = true;
            c.hooks.path = c.hooks.path ?? "/hooks";
            c.hooks.token = c.hooks.token ?? hooksToken;
            c.hooks.defaultSessionKey = c.hooks.defaultSessionKey ?? "agent:main";
          }
        });
      } catch {}
    });

    api.registerHttpRoute({
      path: `${prefix}/voice`,
      auth: "plugin",
      match: "exact",
      handler: async (req: IncomingMessage, res: ServerResponse) => {
        // Auth check
        if (cfg.authToken) {
          const auth = (req.headers["authorization"] as string | undefined) ?? "";
          if (auth !== `Bearer ${cfg.authToken}`) {
            res.statusCode = 401;
            res.setHeader("Content-Type", "application/json");
            res.end(JSON.stringify({ error: "Unauthorized" }));
            return true;
          }
        }

        // Parse multipart audio
        let audioBuffer: Buffer | null = null;
        let audioMime = "audio/wav";
        let audioFilename = "clip.wav";
        try {
          await new Promise<void>((resolve, reject) => {
            const bb = busboy({ headers: req.headers, limits: { fileSize: 100 * 1024 * 1024 } });
            bb.on("file", (field, stream, info) => {
              if (field !== audioField) { stream.resume(); return; }
              audioMime = info.mimeType || audioMime;
              audioFilename = info.filename || audioFilename;
              const chunks: Buffer[] = [];
              stream.on("data", (c: Buffer) => chunks.push(c));
              stream.on("end", () => { audioBuffer = Buffer.concat(chunks); });
              stream.on("error", reject);
            });
            bb.on("close", resolve);
            bb.on("error", reject);
            req.pipe(bb);
          });
        } catch (err) {
          res.statusCode = 400;
          res.setHeader("Content-Type", "application/json");
          res.end(JSON.stringify({ error: "Multipart parse failed", detail: String(err) }));
          return true;
        }

        if (!audioBuffer) {
          res.statusCode = 400;
          res.setHeader("Content-Type", "application/json");
          res.end(JSON.stringify({ error: `Missing audio field "${audioField}"` }));
          return true;
        }

        // Stage to disk
        const stateDir = await api.runtime.state.resolveStateDir(PLUGIN_ID);
        await mkdir(stateDir, { recursive: true });
        const ext = audioFilename.includes(".") ? audioFilename.slice(audioFilename.lastIndexOf(".")) : ".wav";
        const stagedPath = join(stateDir, `clip-${Date.now()}-${randomUUID()}${ext}`);
        await writeFile(stagedPath, audioBuffer);

        // Transcribe
        let transcription: string;
        try {
          if (provider === "openclaw") {
            const result = await api.runtime.mediaUnderstanding.runFile({
              capability: "audio",
              filePath: stagedPath,
              mime: audioMime,
              cfg: api.runtime.config.current() as any,
            });
            transcription = (result?.text ?? "").trim();
            if (!transcription) throw new Error("OpenClaw STT returned empty text");
          } else {
            transcription = await transcribeExternal(stagedPath, audioMime, cfg);
          }
        } catch (err) {
          res.statusCode = 502;
          res.setHeader("Content-Type", "application/json");
          res.end(JSON.stringify({ error: "Transcription failed", detail: String(err) }));
          return true;
        }

        // Respond to app immediately
        res.statusCode = 200;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify({ transcription }));

        // Dispatch to agent via /hooks/agent — fire and forget
        setImmediate(async () => {
          try {
            const runtimeCfg = api.runtime.config.current() as any;
            const hooksToken = runtimeCfg?.hooks?.token as string;
            const hooksPath = (runtimeCfg?.hooks?.path as string) ?? "/hooks";
            const port = process.env.OPENCLAW_GATEWAY_PORT ?? "18789";
            if (!hooksToken) {
              api.logger.warn("Buddy: hooks.token not set — cannot dispatch to agent");
              return;
            }
            await fetch(`http://127.0.0.1:${port}${hooksPath}/agent`, {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                "Authorization": `Bearer ${hooksToken}`,
              },
              body: JSON.stringify({ message: transcription, name: "BuddyVoice" }),
            });
          } catch (err) {
            api.logger.warn("Buddy: dispatch failed: " + String(err));
          }
        });

        return true;
      },
    });

    api.logger.info(`Buddy ready at POST ${prefix}/voice (provider: ${provider})`);
  },
});

async function transcribeExternal(filePath: string, mime: string, cfg: PluginConfig): Promise<string> {
  const provider = cfg.transcriptionProvider ?? "elevenlabs";
  const apiKey = cfg.apiKey ?? "";
  if (!apiKey) throw new Error(`${provider} requires apiKey in plugin config`);

  const buf = await readFile(filePath);
  const blob = new Blob([buf], { type: mime });
  const form = new FormData();

  if (provider === "elevenlabs") {
    form.append("model_id", cfg.model ?? "scribe_v1");
    form.append("diarize", "false");
    form.append("tag_audio_events", "false");
    form.append("file", blob, "clip");
    const res = await fetch("https://api.elevenlabs.io/v1/speech-to-text", {
      method: "POST",
      headers: { "xi-api-key": apiKey },
      body: form,
    });
    if (!res.ok) throw new Error(`ElevenLabs ${res.status}: ${await res.text()}`);
    const json = await res.json() as { text?: string };
    return (json.text ?? "").trim() || (() => { throw new Error("Empty response"); })();
  }

  form.append("model", cfg.model ?? "gpt-4o-transcribe");
  form.append("response_format", "json");
  form.append("file", blob, "clip");
  const res = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}` },
    body: form,
  });
  if (!res.ok) throw new Error(`OpenAI ${res.status}: ${await res.text()}`);
  const json = await res.json() as { text?: string };
  return (json.text ?? "").trim() || (() => { throw new Error("Empty response"); })();
}
