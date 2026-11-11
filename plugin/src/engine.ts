import * as Y from "yjs";
import type { Awareness } from "y-protocols/awareness";
import {
  type BabelSyncClient,
  type DocSession,
  type Entry,
  type VaultSession,
  Emitter,
  RequestError,
  blobHash,
} from "@babelsync/core";
import type { LocalEntry, StateStore, VaultFs } from "./fs.ts";
import { applyTextChange, conflictPath, kindFor, normalize, textHash } from "./text.ts";

export type Status = "offline" | "syncing" | "synced" | "error";

export type EngineOptions = {
  client: BabelSyncClient;
  vaultId: string;
  fs: VaultFs;
  store: StateStore;
  device: string;
  maxBlobBytes?: number;
  ignore?: (path: string) => boolean;
  sessionIdleMs?: number;
  now?: () => Date;
};

export type OpenDoc = {
  text: Y.Text;
  awareness: Awareness;
  writable: boolean;
  release: () => void;
};

type Live = {
  session: DocSession;
  holds: number;
  timer: ReturnType<typeof setTimeout> | null;
  stop: () => void;
};

const DISK = Symbol("disk");

export class SyncEngine extends Emitter<{ status: Status; error: string }> {
  status: Status = "offline";

  private options: EngineOptions;
  private vault: VaultSession | null = null;
  private byId = new Map<string, LocalEntry>();
  private byPath = new Map<string, string>();
  private docs = new Map<string, Y.Doc>();
  private live = new Map<string, Live>();
  private open = new Set<string>();
  private queue: Promise<void> = Promise.resolve();
  private pending = 0;
  private stopped = false;

  constructor(options: EngineOptions) {
    super();
    this.options = options;
  }

  async start(): Promise<void> {
    const { seq, entries } = await this.options.store.load();
    for (const entry of entries) this.remember(entry);

    const vault = this.options.client.vault(this.options.vaultId, seq);
    this.vault = vault;
    vault.on("joined", ({ entries: changes, complete }) => this.run(() => this.reconcile(changes, complete)));
    vault.on("entry", (entry) => this.run(() => this.applyRemote(entry)));
    vault.on("left", () => this.setStatus("offline"));
    vault.on("error", (reason) => {
      this.emit("error", reason);
      this.setStatus("error");
    });
  }

  async stop(): Promise<void> {
    this.stopped = true;
    await this.idle();
    for (const live of this.live.values()) {
      if (live.timer) clearTimeout(live.timer);
      live.stop();
      live.session.close();
    }
    this.live.clear();
    this.vault?.close();
    this.setStatus("offline");
  }

  idle(): Promise<void> {
    return this.queue;
  }

  localChanged(path: string): void {
    this.run(() => this.pushLocal(path));
  }

  localDeleted(path: string): void {
    this.run(() => this.deleteLocal(path));
  }

  localRenamed(from: string, to: string): void {
    this.run(() => this.renameLocal(from, to));
  }

  rescan(): void {
    if (this.online) this.run(() => this.reconcile([]));
  }

  openDoc(path: string): Promise<OpenDoc | null> {
    return this.run(async () => {
      await this.pushLocal(path);
      const id = this.byPath.get(path);
      const entry = id ? this.byId.get(id) : undefined;
      if (!entry || entry.kind !== "doc" || !this.online) return null;

      const live = this.hold(entry.id);
      await live.session.whenSynced();
      await this.settle(entry.id);
      this.open.add(entry.id);

      return {
        text: live.session.text,
        awareness: live.session.awareness,
        writable: live.session.writable,
        release: () => {
          this.run(async () => {
            if (live.session.writable && this.online) await live.session.flush().catch(() => {});
            this.open.delete(entry.id);
            this.release(entry.id);
            if (this.byId.has(entry.id)) await this.writeBack(entry, live.session.text.toString());
          });
        },
      };
    });
  }

  private get online(): boolean {
    return this.vault?.joined === true;
  }

  private run<T>(task: () => Promise<T>): Promise<T> {
    this.pending += 1;
    if (this.online) this.setStatus("syncing");

    const result = this.queue.then(() => (this.stopped ? (undefined as T) : task()));
    this.queue = result.then(
      () => this.finished(),
      (error: unknown) => {
        this.emit("error", error instanceof Error ? error.message : String(error));
        this.finished(true);
      },
    );
    return result;
  }

  private finished(failed = false): void {
    this.pending -= 1;
    if (failed) this.setStatus("error");
    else if (this.pending === 0) this.setStatus(this.online ? "synced" : "offline");
  }

  private setStatus(status: Status): void {
    if (this.status === status) return;
    this.status = status;
    this.emit("status", status);
  }

  private async reconcile(changes: Entry[], complete = false): Promise<void> {
    if (complete) {
      const alive = new Set(changes.map((change) => change.id));
      for (const entry of [...this.byId.values()]) {
        if (!alive.has(entry.id)) await this.removeLocally(entry);
      }
    }

    for (const change of [...changes].sort((a, b) => a.seq - b.seq)) {
      await this.applyRemote(change);
    }

    const files = (await this.options.fs.list()).filter((file) => !this.ignored(file.path));
    const present = new Set(files.map((file) => file.path));

    for (const entry of [...this.byId.values()]) {
      if (entry.moved) await this.pushRename(entry);
    }

    for (const file of files) {
      const id = this.byPath.get(file.path);
      const known = id ? this.byId.get(id) : undefined;
      if (!known || known.mtime !== file.mtime || known.size !== file.size) {
        await this.pushLocal(file.path);
      }
    }

    for (const entry of [...this.byId.values()]) {
      const materialized = entry.kind !== "folder" && entry.hash !== null;
      if (materialized && !present.has(entry.path)) await this.deleteLocal(entry.path);
    }

    for (const entry of [...this.byId.values()]) {
      if (entry.kind === "doc" && entry.dirty) await this.syncDoc(entry.id);
    }

    await this.options.store.setSeq(this.vault!.seq);
  }

  private async applyRemote(remote: Entry): Promise<void> {
    if (this.ignored(remote.path)) return;
    const local = this.byId.get(remote.id);

    if (remote.deleted) {
      if (local) await this.removeLocally(local);
    } else if (!local) {
      await this.adopt(remote);
    } else {
      await this.update(local, remote);
    }

    if (this.vault) await this.options.store.setSeq(this.vault.seq);
  }

  private async removeLocally(local: LocalEntry): Promise<void> {
    const { fs } = this.options;
    const unchanged = local.kind === "folder" || (await this.diskHash(local)) === local.hash;
    this.forget(local);
    await this.options.store.remove(local.id);

    if (local.kind === "folder") return;
    if (unchanged) await fs.remove(local.path);
    else await this.pushLocal(local.path);
  }

  private async adopt(remote: Entry): Promise<void> {
    const { fs } = this.options;
    if (remote.kind === "folder") return;

    await this.vacate(remote.path);

    const entry: LocalEntry = {
      id: remote.id,
      path: remote.path,
      kind: remote.kind,
      hash: null,
      size: 0,
      mtime: 0,
      dirty: false,
      moved: false,
    };

    const existing = await fs.stat(remote.path);

    if (remote.kind === "doc") {
      this.remember(entry);
      const doc = this.doc(entry.id);
      await this.exchange(entry.id);
      const text = doc.getText("content").toString();

      if (existing && normalize(await fs.readText(remote.path)) !== text) {
        await this.pushLocal(await this.setAside(remote.path));
      }
      await this.writeBack(entry, text);
      return;
    }

    if (remote.blob_hash === null) return;
    if (this.tooLarge(remote.size)) {
      this.remember(entry);
      await this.options.store.put(entry);
      return;
    }

    if (existing && (await blobHash(await fs.readBinary(remote.path))) !== remote.blob_hash) {
      await this.pushLocal(await this.setAside(remote.path));
    }

    this.remember(entry);
    await this.download(entry, remote.blob_hash);
  }

  private async update(local: LocalEntry, remote: Entry): Promise<void> {
    const { fs } = this.options;

    if (remote.path !== local.path && !local.moved) {
      await this.vacate(remote.path);
      if (await fs.stat(remote.path)) await this.pushLocal(await this.setAside(remote.path));
      if (await fs.stat(local.path)) await fs.rename(local.path, remote.path);
      this.byPath.delete(local.path);
      local.path = remote.path;
      this.byPath.set(local.path, local.id);
      await this.options.store.put(local);
    }

    if (remote.kind === "doc") {
      const missing = (await fs.stat(local.path)) === null;
      if (missing || (remote.content_hash !== null && remote.content_hash !== local.hash)) {
        await this.syncDoc(local.id);
      }
    } else if (remote.kind === "blob" && remote.blob_hash && remote.blob_hash !== local.hash) {
      if (this.tooLarge(remote.size)) return;
      const disk = await this.diskHash(local);
      if (disk !== null && disk !== local.hash && disk !== remote.blob_hash) {
        await this.pushLocal(await this.setAside(local.path));
      }
      if (disk !== remote.blob_hash) await this.download(local, remote.blob_hash);
      else await this.record(local, remote.blob_hash);
    }
  }

  private async pushLocal(path: string): Promise<void> {
    if (this.ignored(path)) return;
    const { fs } = this.options;
    const file = await fs.stat(path);
    if (!file) return;

    const id = this.byPath.get(path);
    const entry = id ? this.byId.get(id) : undefined;

    if (kindFor(path) === "doc") await this.pushText(path, entry);
    else if (!this.tooLarge(file.size)) await this.pushBlob(path, entry);
  }

  private async pushText(path: string, entry: LocalEntry | undefined): Promise<void> {
    const { fs } = this.options;
    const text = normalize(await fs.readText(path));
    const hash = await textHash(text);

    if (entry) {
      if (entry.kind !== "doc") return;
      if (hash === entry.hash) return this.touch(entry);

      if (this.open.has(entry.id)) {
        if (this.doc(entry.id).getText("content").toString() === text) await this.record(entry, hash);
        return;
      }

      await this.syncDoc(entry.id);
      return;
    }

    if (!this.online) return;

    try {
      const created = await this.vault!.create(path, { text });
      const fresh: LocalEntry = {
        id: created.id,
        path: created.path,
        kind: "doc",
        hash: null,
        size: 0,
        mtime: 0,
        dirty: false,
        moved: false,
      };
      this.remember(fresh);
      await this.exchange(fresh.id);
      await this.record(fresh, hash);
    } catch (error) {
      if (error instanceof RequestError && error.reason === "exists" && error.entry) {
        await this.applyRemote(error.entry);
      } else {
        throw error;
      }
    }
  }

  private async pushBlob(path: string, entry: LocalEntry | undefined): Promise<void> {
    const { fs, client, vaultId } = this.options;
    const data = await fs.readBinary(path);
    const hash = await blobHash(data);

    if (entry && hash === entry.hash) return this.touch(entry);
    if (!this.online) return;

    await client.upload(vaultId, data);

    try {
      if (entry) {
        await this.vault!.setBlob(entry.id, hash, entry.hash);
        await this.record(entry, hash);
      } else {
        const created = await this.vault!.create(path, { blobHash: hash, kind: "blob" });
        const fresh: LocalEntry = {
          id: created.id,
          path: created.path,
          kind: "blob",
          hash: null,
          size: 0,
          mtime: 0,
          dirty: false,
          moved: false,
        };
        this.remember(fresh);
        await this.record(fresh, hash);
      }
    } catch (error) {
      if (!(error instanceof RequestError) || !error.entry) throw error;
      if (error.reason !== "exists" && error.reason !== "conflict") throw error;
      await this.applyRemote(error.entry);
    }
  }

  private async deleteLocal(path: string): Promise<void> {
    const id = this.byPath.get(path);
    const entry = id ? this.byId.get(id) : undefined;
    if (!entry || !this.online) return;
    if (await this.options.fs.stat(path)) return;

    try {
      await this.vault!.remove(entry.id);
    } catch (error) {
      if (!(error instanceof RequestError) || error.reason !== "not_found") throw error;
    }

    this.forget(entry);
    await this.options.store.remove(entry.id);
  }

  private async renameLocal(from: string, to: string): Promise<void> {
    const id = this.byPath.get(from);
    const entry = id ? this.byId.get(id) : undefined;
    if (!entry) return this.pushLocal(to);
    if (this.ignored(to)) return this.deleteLocal(from);

    this.byPath.delete(from);
    entry.path = to;
    entry.moved = true;
    this.byPath.set(to, entry.id);
    await this.options.store.put(entry);
    if (this.online) await this.pushRename(entry);
  }

  private async pushRename(entry: LocalEntry): Promise<void> {
    try {
      await this.vault!.rename(entry.id, entry.path);
    } catch (error) {
      if (!(error instanceof RequestError) || error.reason !== "exists") throw error;
      const aside = await this.setAside(entry.path);
      this.byPath.delete(entry.path);
      entry.path = aside;
      this.byPath.set(aside, entry.id);
      await this.vault!.rename(entry.id, aside);
    }

    entry.moved = false;
    await this.options.store.put(entry);
  }

  private async syncDoc(id: string): Promise<void> {
    const entry = this.byId.get(id);
    if (!entry || this.open.has(id)) return;

    await this.absorb(entry);
    if (this.online) await this.exchange(id, entry.dirty);
    await this.settle(id);
  }

  private async exchange(id: string, announce = false): Promise<void> {
    const live = this.hold(id);
    try {
      await live.session.whenSynced();
      if (announce && live.session.writable) await live.session.flush();
      const entry = this.byId.get(id);
      if (entry && live.session.writable) entry.dirty = false;
    } finally {
      this.release(id);
    }
  }

  private async settle(id: string): Promise<void> {
    const entry = this.byId.get(id);
    if (!entry || this.open.has(id)) return;

    const absorbed = await this.absorb(entry);
    if (absorbed && this.online) await this.exchange(id, true);
    await this.writeBack(entry, this.doc(id).getText("content").toString());
  }

  private async absorb(entry: LocalEntry): Promise<boolean> {
    const { fs } = this.options;
    if (entry.hash === null || !(await fs.stat(entry.path))) return false;

    const disk = normalize(await fs.readText(entry.path));
    const hash = await textHash(disk);
    if (hash === entry.hash) return false;

    const fork = new Y.Doc();
    if (entry.doc) Y.applyUpdate(fork, entry.doc);
    applyTextChange(fork.getText("content"), disk, DISK);
    const forked = Y.encodeStateAsUpdate(fork);
    fork.destroy();
    Y.applyUpdate(this.doc(entry.id), forked, DISK);

    entry.doc = forked;
    entry.hash = hash;
    entry.dirty = true;
    await this.touch(entry);
    return true;
  }

  private async writeBack(entry: LocalEntry, text: string): Promise<void> {
    const { fs } = this.options;
    const file = await fs.stat(entry.path);
    const disk = file ? normalize(await fs.readText(entry.path)) : null;
    if (disk !== text) await fs.writeText(entry.path, text);
    await this.record(entry, await textHash(text));
  }

  private async download(entry: LocalEntry, hash: string): Promise<void> {
    const data = await this.options.client.download(this.options.vaultId, hash);
    await this.options.fs.writeBinary(entry.path, data);
    await this.record(entry, hash);
  }

  private async record(entry: LocalEntry, hash: string): Promise<void> {
    entry.hash = hash;
    if (entry.kind === "doc") entry.doc = Y.encodeStateAsUpdate(this.doc(entry.id));
    await this.touch(entry);
  }

  private async touch(entry: LocalEntry): Promise<void> {
    const file = await this.options.fs.stat(entry.path);
    entry.size = file?.size ?? 0;
    entry.mtime = file?.mtime ?? 0;
    await this.options.store.put(entry);
  }

  private async setAside(path: string): Promise<string> {
    const { fs, device } = this.options;
    const aside = conflictPath(path, device, (this.options.now ?? (() => new Date()))());
    await fs.rename(path, aside);
    return aside;
  }

  private async vacate(path: string): Promise<void> {
    const id = this.byPath.get(path);
    const holder = id ? this.byId.get(id) : undefined;
    if (!holder) return;

    if (holder.moved && (await this.options.fs.stat(path))) {
      const aside = await this.setAside(path);
      this.byPath.delete(path);
      holder.path = aside;
      this.byPath.set(aside, holder.id);
      await this.options.store.put(holder);
      return;
    }

    this.forget(holder);
    await this.options.store.remove(holder.id);
  }

  private async diskHash(entry: LocalEntry): Promise<string | null> {
    const { fs } = this.options;
    if (!(await fs.stat(entry.path))) return null;
    if (entry.kind === "doc") return textHash(normalize(await fs.readText(entry.path)));
    return blobHash(await fs.readBinary(entry.path));
  }

  private doc(id: string): Y.Doc {
    let doc = this.docs.get(id);
    if (!doc) {
      doc = new Y.Doc();
      const saved = this.byId.get(id)?.doc;
      if (saved) Y.applyUpdate(doc, saved);
      this.docs.set(id, doc);
    }
    return doc;
  }

  private hold(id: string): Live {
    let live = this.live.get(id);

    if (!live) {
      const doc = this.doc(id);
      const session = this.options.client.doc(id, doc);
      const onUpdate = (_update: Uint8Array, origin: unknown) => {
        if (origin === session && !this.open.has(id)) this.run(() => this.settle(id));
      };
      doc.on("update", onUpdate);
      live = { session, holds: 0, timer: null, stop: () => doc.off("update", onUpdate) };
      this.live.set(id, live);
    }

    if (live.timer) clearTimeout(live.timer);
    live.timer = null;
    live.holds += 1;
    return live;
  }

  private release(id: string): void {
    const live = this.live.get(id);
    if (!live) return;
    live.holds -= 1;
    if (live.holds > 0) return;

    live.timer = setTimeout(() => {
      live.stop();
      live.session.close();
      this.live.delete(id);
      if (this.docs.size > 200 && !this.open.has(id)) this.docs.delete(id);
    }, this.options.sessionIdleMs ?? 30_000);
  }

  private remember(entry: LocalEntry): void {
    this.byId.set(entry.id, entry);
    this.byPath.set(entry.path, entry.id);
  }

  private forget(entry: LocalEntry): void {
    this.byId.delete(entry.id);
    if (this.byPath.get(entry.path) === entry.id) this.byPath.delete(entry.path);
    this.docs.delete(entry.id);
    this.open.delete(entry.id);

    const live = this.live.get(entry.id);
    if (live) {
      if (live.timer) clearTimeout(live.timer);
      live.stop();
      live.session.close();
      this.live.delete(entry.id);
    }
  }

  private ignored(path: string): boolean {
    return this.options.ignore?.(path) ?? false;
  }

  private tooLarge(size: number): boolean {
    const limit = this.options.maxBlobBytes;
    return limit !== undefined && size > limit;
  }
}
