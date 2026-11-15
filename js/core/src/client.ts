import { Socket } from "phoenix";
import type * as Y from "yjs";
import { type BlobApi, type Fetch, downloadBlob, uploadBlob } from "./blobs.ts";
import { DocSession } from "./doc.ts";
import { fetchDocs } from "./docs.ts";
import { type Against, type VersionDetail, type VersionSummary, compareVersion, listVersions, restoreVersion } from "./history.ts";
import { VaultSession } from "./vault.ts";

export type ClientOptions = {
  baseUrl: string;
  token?: () => string | undefined;
  transport?: unknown;
  fetch?: Fetch;
};

export class BabelSyncClient {
  readonly socket: Socket;
  private api: BlobApi;

  constructor(options: ClientOptions) {
    const baseUrl = options.baseUrl.replace(/\/+$/, "");
    this.api = { baseUrl, token: options.token, fetch: options.fetch };

    this.socket = new Socket(`${baseUrl.replace(/^http/, "ws")}/socket`, {
      params: () => {
        const token = options.token?.();
        return token ? { token } : {};
      },
      ...(options.transport ? { transport: options.transport as never } : {}),
    });
  }

  connect(): void {
    this.socket.connect();
  }

  probe(timeoutMs = 5000): void {
    const socket = this.socket;
    if (!socket.isConnected()) return void socket.connect();

    const probed = this.connection();
    const ref = socket.makeRef();
    let answered = false;
    const listening = socket.onMessage((message: { ref?: string | null }) => {
      if (message.ref === ref) answered = true;
    });
    socket.push({ topic: "phoenix", event: "heartbeat", payload: {}, ref });

    setTimeout(() => {
      socket.off([listening]);
      if (answered || this.connection() !== probed) return;
      socket.disconnect(() => socket.connect());
    }, timeoutMs);
  }

  private connection(): unknown {
    return (this.socket as unknown as { connection?: unknown }).connection;
  }

  disconnect(): Promise<void> {
    return new Promise((resolve) => this.socket.disconnect(() => resolve()));
  }

  vault(vaultId: string, since = 0): VaultSession {
    return new VaultSession(this.socket, vaultId, since);
  }

  doc(entryId: string, doc?: Y.Doc): DocSession {
    return new DocSession(this.socket, entryId, doc);
  }

  upload(vaultId: string, data: Uint8Array, onProgress?: (sent: number, total: number) => void) {
    return uploadBlob(this.api, vaultId, data, onProgress);
  }

  docs(vaultId: string, ids: string[]): Promise<Map<string, Uint8Array[]>> {
    return fetchDocs(this.api, vaultId, ids);
  }

  versions(vaultId: string, entryId: string): Promise<VersionSummary[]> {
    return listVersions(this.api, vaultId, entryId);
  }

  version(vaultId: string, entryId: string, id: number, against: Against): Promise<VersionDetail> {
    return compareVersion(this.api, vaultId, entryId, id, against);
  }

  restore(vaultId: string, entryId: string, id: number): Promise<void> {
    return restoreVersion(this.api, vaultId, entryId, id);
  }

  download(vaultId: string, hash: string): Promise<Uint8Array> {
    return downloadBlob(this.api, vaultId, hash);
  }
}
