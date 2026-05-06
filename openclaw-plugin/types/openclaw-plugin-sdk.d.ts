// Local type stubs so this plugin can build without a workspace install of
// the OpenClaw runtime. Real types come from the host at load time.
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
