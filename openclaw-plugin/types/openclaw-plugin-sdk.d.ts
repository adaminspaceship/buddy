// Permissive stubs for OpenClaw plugin SDK subpaths so this plugin can build
// outside the OpenClaw monorepo. Real types come from the host at load time.

declare module "openclaw/plugin-sdk/plugin-entry" {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  export type PluginApi = any;

  export interface PluginEntryDefinition {
    id: string;
    name: string;
    register(api: PluginApi): void | Promise<void>;
  }

  export function definePluginEntry(def: PluginEntryDefinition): PluginEntryDefinition;
}

declare module "openclaw/plugin-sdk/webhook-ingress" {
  import type { IncomingMessage, ServerResponse } from "node:http";
  export interface RegisterPluginHttpRouteOptions {
    auth: "plugin" | "public" | string;
    match: "exact" | "prefix";
    path: string;
    pluginId: string;
    source: string;
    accountId?: string;
    log?: { info: (...a: unknown[]) => void; warn: (...a: unknown[]) => void; error: (...a: unknown[]) => void };
    handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void>;
  }
  export function registerPluginHttpRoute(opts: RegisterPluginHttpRouteOptions): { unregister: () => void };
}
