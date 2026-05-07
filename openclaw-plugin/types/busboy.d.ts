declare module "busboy" {
  import type { Readable } from "node:stream";
  import type { IncomingHttpHeaders } from "node:http";

  export interface BusboyConfig {
    headers: IncomingHttpHeaders;
    limits?: { fileSize?: number };
  }

  export interface BusboyFileInfo {
    filename: string;
    encoding: string;
    mimeType: string;
  }

  export interface Busboy extends NodeJS.WritableStream {
    on(event: "file", listener: (name: string, file: Readable, info: BusboyFileInfo) => void): this;
    on(event: "field", listener: (name: string, value: string) => void): this;
    on(event: "close", listener: () => void): this;
    on(event: "error", listener: (err: Error) => void): this;
    on(event: "finish", listener: () => void): this;
  }

  export default function busboy(config: BusboyConfig): Busboy;
}
