import type { Channel, Socket } from "phoenix";
import { Emitter } from "./events.ts";

export type EntryKind = "doc" | "blob" | "folder";

export type Entry = {
  id: string;
  path: string;
  kind: EntryKind;
  blob_hash: string | null;
  content_hash: string | null;
  size: number;
  seq: number;
  deleted: boolean;
  updated_at: string;
};

type JoinReply = { seq: number; name: string; writable: boolean; complete: boolean; entries: Entry[] };

type VaultEvents = {
  entry: Entry;
  joined: { entries: Entry[]; seq: number; complete: boolean };
  left: undefined;
  error: string;
};

export class RequestError extends Error {
  readonly reason: string;
  readonly entry?: Entry;

  constructor(reason: string, entry?: Entry) {
    super(reason);
    this.reason = reason;
    this.entry = entry;
  }
}

export class VaultSession extends Emitter<VaultEvents> {
  readonly vaultId: string;
  readonly entries = new Map<string, Entry>();
  name = "";
  writable = false;
  seq: number;
  joined = false;

  private channel: Channel;
  private latest = new Map<string, number>();

  constructor(socket: Socket, vaultId: string, since = 0) {
    super();
    this.vaultId = vaultId;
    this.seq = since;
    this.channel = socket.channel(`vault:${vaultId}`, () => ({ since: this.seq }));
    this.channel.on("entry", (entry: Entry) => this.apply(entry, true));
    this.channel.onClose(() => this.left());
    this.channel.onError(() => this.left());

    this.channel
      .join()
      .receive("ok", (reply: JoinReply) => {
        this.name = reply.name;
        this.writable = reply.writable;
        this.joined = true;
        if (reply.complete) this.entries.clear();
        for (const entry of reply.entries) this.apply(entry, false);
        this.seq = Math.max(this.seq, reply.seq);
        this.emit("joined", { entries: reply.entries, seq: this.seq, complete: reply.complete });
      })
      .receive("error", (reply: { reason?: string }) => this.emit("error", reply.reason ?? "error"));
  }

  whenJoined(timeoutMs = 15000): Promise<void> {
    if (this.joined) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const finish = (error?: Error) => {
        clearTimeout(timer);
        stopReady();
        stopError();
        if (error) reject(error);
        else resolve();
      };
      const timer = setTimeout(() => finish(new Error("timed out waiting for joined")), timeoutMs);
      const stopReady = this.on("joined", () => {
        if (this.joined) finish();
      });
      const stopError = this.on("error", (reason) => finish(new Error(reason)));
    });
  }

  byPath(path: string): Entry | undefined {
    for (const entry of this.entries.values()) if (entry.path === path) return entry;
    return undefined;
  }

  async create(
    path: string,
    content: { text?: string; blobHash?: string; kind?: EntryKind } = {},
  ): Promise<Entry> {
    const reply = await this.request<{ entry: Entry }>("create", {
      path,
      kind: content.kind,
      text: content.text,
      blob_hash: content.blobHash,
    });
    this.apply(reply.entry, false);
    return reply.entry;
  }

  async rename(id: string, path: string): Promise<Entry[]> {
    const reply = await this.request<{ entries: Entry[] }>("rename", { id, path });
    for (const entry of reply.entries) this.apply(entry, false);
    return reply.entries;
  }

  async remove(id: string): Promise<Entry[]> {
    const reply = await this.request<{ entries: Entry[] }>("delete", { id });
    for (const entry of reply.entries) this.apply(entry, false);
    return reply.entries;
  }

  async setBlob(id: string, blobHash: string, baseHash?: string | null): Promise<Entry> {
    const payload: Record<string, unknown> = { id, blob_hash: blobHash };
    if (baseHash !== undefined) payload.base_hash = baseHash;
    const reply = await this.request<{ entry: Entry }>("set_blob", payload);
    this.apply(reply.entry, false);
    return reply.entry;
  }

  close(): void {
    this.channel.leave();
  }

  private request<T>(event: string, payload: object): Promise<T> {
    return new Promise((resolve, reject) => {
      this.channel
        .push(event, payload)
        .receive("ok", (reply: T) => resolve(reply))
        .receive("error", (reply: { reason?: string; entry?: Entry }) =>
          reject(new RequestError(reply.reason ?? "error", reply.entry)),
        )
        .receive("timeout", () => reject(new RequestError("timeout")));
    });
  }

  private apply(entry: Entry, announce: boolean): void {
    if ((this.latest.get(entry.id) ?? -1) >= entry.seq) return;
    this.latest.set(entry.id, entry.seq);

    if (entry.deleted) this.entries.delete(entry.id);
    else this.entries.set(entry.id, entry);

    this.seq = Math.max(this.seq, entry.seq);
    if (announce) this.emit("entry", entry);
  }

  private left(): void {
    if (!this.joined) return;
    this.joined = false;
    this.emit("left", undefined);
  }
}
