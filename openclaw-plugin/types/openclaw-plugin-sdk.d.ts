// Local type stubs for @openclaw/plugin-sdk so this plugin can build without
// the workspace package (it's only available inside the OpenClaw monorepo).
// The real types come from the host runtime at load time.
declare module "@openclaw/plugin-sdk" {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  export type PluginApi = any;

  export interface PluginEntryDefinition {
    id: string;
    name: string;
    register(api: PluginApi): void | Promise<void>;
  }

  export function definePluginEntry(def: PluginEntryDefinition): PluginEntryDefinition;
}
