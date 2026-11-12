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
import { type LocalEntry, type StateStore, type VaultFs, parentOf } from "./fs.ts";
import { applyTextChange, conflictPath, kindFor, normalize, textHash } from "./text.ts";

function numbered(path: string, copy: number): string {
  const dot = path.lastIndexOf(".");
  return dot > path.lastIndexOf("/") ? `${path.slice(0, dot)} ${copy}${path.slice(dot)}` : `${path} ${copy}`;
}

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
  retryMs?: number;
  settleMs?: number;
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
const MAX_RESTING_SESSIONS = 16;
const FIRST_RETRY_MS = 20_000;
const LONGEST_RETRY_MS = 300_000;
const NEVER_CONFIRMED = -1;
const UNCONDITIONAL = null;
const SETTLE_MS = 1_000;
const STOP_GRACE_MS = 3_000;
const SETTLING_PASSES = 5;
const QUIETLY = true;
const ATTEMPTS = 3;

function folded(path: string): string {
  return path.normalize("NFC").toLowerCase();
}

class Unplaceable extends Error {}

async function placing<T>(work: Promise<T>): Promise<T> {
  try {
    return await work;
  } catch (error) {
    throw new Unplaceable(error instanceof Error ? error.message : String(error));
  }
}

export type Progress = { direction: "receiving" | "sending"; done: number; total: number };

export class SyncEngine extends Emitter<{ status: Status; error: string; progress: Progress | null; log: string }> {
  status: Status = "offline";
  progress: Progress | null = null;

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
  private versions = new Map<string, number>();
  private applied = 0;
  private behind = false;
  private retry: ReturnType<typeof setTimeout> | null = null;
  private retryMs = 0;
  private settling: ReturnType<typeof setTimeout> | null = null;
  private changes = 0;
  private settled = 0;
  private passes = 0;
  private failures = new Map<string, number>();
  private buried = new Map<string, number>();

  constructor(options: EngineOptions) {
    super();
    this.options = options;
  }

  async start(): Promise<void> {
    const { seq, entries } = await this.options.store.load();
    for (const entry of entries) {
      const unfetched = entry.kind !== "folder" && entry.hash === null && !entry.unwanted;
      if (entry.seq !== undefined && !unfetched) this.versions.set(entry.id, entry.seq);
      if (!entry.unwanted && this.ignored(entry.path)) await this.options.store.put({ ...entry, doc: undefined, hash: null, unwanted: true });
      else if (!entry.unwanted) this.remember(entry);
      else if (!this.ignored(entry.path)) await this.discard(entry.id);
    }

    this.applied = seq;
    this.retryMs = this.firstRetryMs;
    this.attach(seq);
  }

  private attach(since: number): void {
    this.vault?.close();
    const vault = this.options.client.vault(this.options.vaultId, since);
    const current = () => this.vault === vault;
    this.vault = vault;

    vault.on("joined", ({ entries: changes, complete, seq, digest }) =>
      this.run(async () => {
        if (!current()) return;
        const recovering = this.behind;

        await this.reconcile(changes, complete, recovering ? UNCONDITIONAL : digest);
        if (!current() || this.behind) return;
        if (!recovering) await this.advance(seq);
        this.retryMs = this.firstRetryMs;
      }),
    );
    vault.on("entry", (entry) => this.run(async () => void (current() && (await this.receive(entry)))));
    vault.on("acknowledged", (entry) => current() && this.acknowledge(entry));
    vault.on("left", () => void (current() && this.setStatus("offline")));
    vault.on("error", (reason) => {
      if (!current()) return;
      this.emit("error", reason);
      this.setStatus("error");
    });
  }

  private get firstRetryMs(): number {
    return this.options.retryMs ?? FIRST_RETRY_MS;
  }

  private acknowledge(entry: Entry): void {
    if (!entry.deleted) return void this.versions.set(entry.id, entry.seq);
    this.versions.delete(entry.id);
    this.buried.set(entry.id, entry.seq);
  }

  private async audit(): Promise<void> {
    const { entries, gone } = await this.vault!.audit(Object.fromEntries(this.held()));
    this.emit("log", `audit: the server differs on ${entries.length} entries and no longer has ${gone.length}`);

    for (const id of gone) {
      const local = this.byId.get(id);
      if (!local) await this.discard(id);
      else if (this.versions.has(id)) await this.removeLocally(local);
      else await this.sendAsNew(local);
    }
    for (const entry of entries) await this.receive(entry);
  }

  private held(): Map<string, number> {
    const held = new Map<string, number>();
    for (const id of this.byId.keys()) held.set(id, NEVER_CONFIRMED);
    for (const [id, seq] of this.versions) held.set(id, seq);
    return held;
  }

  private async digest(): Promise<string> {
    const lines = [...this.held()]
      .sort(([one], [other]) => (one < other ? -1 : 1))
      .map(([id, seq]) => `${id}:${seq}\n`);
    return textHash(lines.join(""));
  }

  private async take(remote: Entry): Promise<void> {
    const seen = this.versions.get(remote.id) ?? this.buried.get(remote.id);
    if (seen !== undefined && seen >= remote.seq) return;

    if (this.ignored(remote.path) && !this.byId.has(remote.id)) return this.pass(remote);
    await this.applyRemote(remote);
    await this.mark(remote);
  }

  private async mark(remote: Entry): Promise<void> {
    this.acknowledge(remote);
    const local = this.byId.get(remote.id);
    if (local) await this.persist(local);
  }

  private async pass(remote: Entry): Promise<void> {
    if (remote.deleted) return this.discard(remote.id);

    this.versions.set(remote.id, remote.seq);
    await this.options.store.put({
      id: remote.id,
      path: remote.path,
      kind: remote.kind,
      hash: null,
      size: 0,
      mtime: 0,
      dirty: false,
      moved: false,
      unwanted: true,
      seq: remote.seq,
    });
  }

  private persist(entry: LocalEntry): Promise<void> {
    return this.options.store.put({ ...entry, seq: this.versions.get(entry.id) });
  }

  private async discard(id: string): Promise<void> {
    this.versions.delete(id);
    await this.options.store.remove(id);
  }

  private async receive(remote: Entry): Promise<void> {
    try {
      await this.take(remote);
      this.failures.delete(remote.id);
      await this.advance(remote.seq);
    } catch (error) {
      this.emit("log", `could not apply ${remote.path}: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}`);
      const attempts = error instanceof Unplaceable ? (this.failures.get(remote.id) ?? 0) + 1 : 0;
      this.failures.set(remote.id, attempts);
      if (attempts >= ATTEMPTS) return this.giveUp(remote);
      this.emit("error", error instanceof Error ? error.message : String(error));
      this.fallBehind();
    }
  }

  private async giveUp(remote: Entry): Promise<void> {
    this.failures.delete(remote.id);
    this.emit("log", `leaving ${remote.path} out after ${ATTEMPTS} attempts`);
    this.emit("error", `${remote.path} cannot be kept on this device`);
    if (this.byId.has(remote.id)) await this.mark(remote);
    else await this.pass(remote);
    await this.advance(remote.seq);
  }

  private async advance(seq: number): Promise<void> {
    if (this.behind || seq <= this.applied) return;
    this.applied = seq;
    await this.options.store.setSeq(seq);
  }

  private fallBehind(): void {
    this.behind = true;
    if (this.retry || this.stopped) return;

    this.retry = setTimeout(() => {
      this.retry = null;
      if (!this.stopped && this.online) void this.run(() => this.reconcile([], false, UNCONDITIONAL)).catch(() => {});
    }, this.retryMs);
    this.retryMs = Math.min(this.retryMs * 2, LONGEST_RETRY_MS);
  }

  async stop(): Promise<void> {
    this.stopped = true;
    if (this.retry) clearTimeout(this.retry);
    if (this.settling) clearTimeout(this.settling);
    this.retry = null;
    this.settling = null;
    await Promise.race([this.idle(), new Promise((resolve) => setTimeout(resolve, STOP_GRACE_MS))]);
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

  localFolderCreated(folder: string): void {
    this.run(() => this.pushFolder(folder));
  }

  localFolderDeleted(folder: string): void {
    this.run(async () => {
      for (const path of this.under(folder, "files")) await this.deleteLocal(path);
      for (const path of this.under(folder, "folders")) await this.deleteFolder(path);
      await this.pushFolder(parentOf(folder));
    });
  }

  localFolderRenamed(from: string, to: string): void {
    this.run(async () => {
      for (const path of [...this.under(from, "files"), ...this.under(from, "folders")]) {
        await this.renameLocal(path, to + path.slice(from.length));
      }
      await this.pushFolder(parentOf(from));
    });
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
      if (!(await this.reached(entry.id, live))) return null;
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

  private get sending(): boolean {
    return this.online && this.vault!.writable;
  }

  private run<T>(task: () => Promise<T>, quietly = false): Promise<T> {
    this.pending += 1;
    if (!quietly) {
      this.changes += 1;
      this.passes = 0;
    }
    if (this.online) this.setStatus("syncing");

    const result = this.queue.then(() => (this.stopped ? (undefined as T) : task()));
    this.queue = result.then(
      () => this.finished(),
      (error: unknown) => {
        if (this.stopped) return this.finished();
        this.emit("log", `failed: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}`);
        this.emit("error", error instanceof Error ? error.message : String(error));
        this.fallBehind();
        this.finished(true);
      },
    );
    return result;
  }

  private finished(failed = false): void {
    this.pending -= 1;
    if (failed) return this.setStatus("error");
    if (this.pending > 0) return;
    if (!this.online) return this.setStatus("offline");
    if (this.behind) return this.setStatus("error");
    if (this.settled === this.changes) return this.setStatus("synced");
    this.settleSoon();
  }

  get fileCount(): number {
    return this.byId.size;
  }

  private report(direction: Progress["direction"] | null, done = 0, total = 0): void {
    const progress = direction && total > 1 ? { direction, done, total } : null;
    if (!progress && !this.progress) return;
    this.progress = progress;
    this.emit("progress", progress);
  }

  private setStatus(status: Status): void {
    if (status !== "syncing") this.report(null);
    if (this.status === status) return;
    this.status = status;
    this.emit("status", status);
  }

  private async reconcile(changes: Entry[], complete = false, digest?: string | null): Promise<void> {
    if (digest === UNCONDITIONAL) this.behind = false;
    this.emit("log", `reconcile: ${changes.length} changes${complete ? ", complete listing" : ""}, ${this.byId.size} known`);
    if (complete) {
      const alive = new Set(changes.map((change) => change.id));
      for (const entry of [...this.byId.values()]) {
        if (!alive.has(entry.id)) await this.removeLocally(entry);
      }
    }

    const incoming = [...changes].sort((a, b) => a.seq - b.seq);
    for (const [done, change] of incoming.entries()) {
      this.report("receiving", done, incoming.length);
      await this.receive(change);
    }

    if (digest === UNCONDITIONAL || (digest !== undefined && !this.behind && digest !== (await this.digest()))) {
      await this.audit();
    }

    await this.sweep();
    if (digest === UNCONDITIONAL && !this.behind) this.retryMs = this.firstRetryMs;
  }

  private async sweep(): Promise<boolean> {
    const files = (await this.options.fs.list()).filter((file) => !this.ignored(file.path));
    const present = new Set(files.map((file) => file.path));
    const entries = () => [...this.byId.values()];

    const displaced = entries().filter((entry) => this.byPath.get(entry.path) !== entry.id);
    for (const entry of displaced) await this.drop(entry);

    const moved = entries().filter((entry) => entry.moved);
    for (const entry of moved) if (this.sending) await this.pushRename(entry);

    const outgoing = files.filter((file) => {
      const id = this.byPath.get(file.path);
      const known = id ? this.byId.get(id) : undefined;
      const kind = known && known.kind !== "folder" ? known.kind : kindFor(file.path);
      if (kind !== "doc" && this.tooLarge(file.size)) return false;
      return !known || known.mtime !== file.mtime || known.size !== file.size;
    });
    for (const [done, file] of outgoing.entries()) {
      this.report("sending", done, outgoing.length);
      await this.pushLocal(file.path);
    }
    this.report(null);

    const missing = entries().filter((entry) => entry.kind !== "folder" && entry.hash !== null && !present.has(entry.path));
    for (const entry of missing) await this.deleteLocal(entry.path);

    const unsent = entries().filter((entry) => entry.kind === "doc" && entry.dirty);
    for (const entry of unsent) await this.syncDoc(entry.id);

    await this.tidyFolders();
    return displaced.length + moved.length + outgoing.length + missing.length + unsent.length > 0;
  }

  private settleSoon(): void {
    if (this.settling) clearTimeout(this.settling);
    this.settling = setTimeout(() => {
      this.settling = null;
      if (this.stopped || !this.online) return;
      void this.run(async () => {
        const seen = this.changes;
        const acted = await this.sweep();
        this.passes = acted ? this.passes + 1 : 0;
        if (acted && this.passes < SETTLING_PASSES) return;
        if (acted) this.emit("log", `still finding local changes after ${this.passes} passes`);
        this.settled = seen;
      }, QUIETLY).catch(() => {});
    }, this.options.settleMs ?? SETTLE_MS);
  }

  private async applyRemote(remote: Entry): Promise<void> {
    if (this.ignored(remote.path)) return;
    const local = this.byId.get(remote.id);

    if (remote.deleted) {
      if (local) await this.removeLocally(local);
      else if (remote.kind === "folder") await this.prune(remote.path);
    } else if (!local) {
      await this.adopt(remote);
    } else {
      await this.update(local, remote);
    }
  }

  private async removeLocally(local: LocalEntry): Promise<void> {
    const { fs } = this.options;
    const edited = local.kind !== "folder" && (local.dirty || (await this.diskHash(local)) !== local.hash);
    if (local.kind !== "folder" && !edited) await fs.remove(local.path);
    this.forget(local);
    await this.discard(local.id);

    if (local.kind === "folder") return this.prune(local.path);
    if (edited) return this.pushLocal(local.path);
    await this.prune(parentOf(local.path));
  }

  private prune(folder: string): Promise<void> {
    return this.options.fs.prune(folder, (path) => this.folderAt(path) !== undefined);
  }

  private folderAt(path: string): LocalEntry | undefined {
    const id = this.byPath.get(path);
    const entry = id ? this.byId.get(id) : undefined;
    return entry?.kind === "folder" ? entry : undefined;
  }

  private async keepFolder(remote: Entry): Promise<void> {
    const entry: LocalEntry = {
      id: remote.id,
      path: remote.path,
      kind: "folder",
      hash: null,
      size: 0,
      mtime: 0,
      dirty: false,
      moved: false,
    };
    this.remember(entry);
    await this.persist(entry);
  }

  private async pushFolder(folder: string): Promise<void> {
    if (folder === "" || this.ignored(folder + "/") || this.byPath.has(folder) || !this.sending) return;
    if ((await this.options.fs.folderState(folder)) !== "empty") return;

    try {
      await this.keepFolder(await this.vault!.create(folder, { kind: "folder" }));
    } catch (error) {
      if (!(error instanceof RequestError) || error.reason !== "exists" || !error.entry) throw error;
      if (error.entry.kind === "folder") await this.keepFolder(error.entry);
    }
  }

  private async deleteFolder(folder: string): Promise<void> {
    const entry = this.folderAt(folder);
    if (!entry || !this.sending) return;
    if ((await this.options.fs.folderState(folder)) !== "missing") return;

    try {
      await this.vault!.remove(entry.id, { ifEmpty: true });
    } catch (error) {
      if (error instanceof RequestError && error.reason === "not_empty") return;
      if (!this.gone(error)) throw error;
    }

    this.forget(entry);
    await this.discard(entry.id);
  }

  private async tidyFolders(): Promise<void> {
    const { fs } = this.options;

    for (const entry of [...this.byId.values()]) {
      if (entry.kind === "folder" && (await fs.folderState(entry.path)) === "missing") await fs.makeFolder(entry.path);
    }
    for (const folder of await fs.emptyFolders()) {
      if (!this.ignored(folder + "/")) await this.prune(folder);
    }
  }

  private under(folder: string, kind: "files" | "folders"): string[] {
    const wanted = (path: string) => (this.folderAt(path) !== undefined) === (kind === "folders");
    const paths = [...this.byPath.keys()].filter((path) => (path === folder || path.startsWith(folder + "/")) && wanted(path));
    return paths.sort((a, b) => b.length - a.length);
  }

  private async adopt(remote: Entry): Promise<void> {
    const { fs } = this.options;
    if (remote.kind === "folder") {
      await this.keepFolder(remote);
      if (!(await fs.stat(remote.path))) await placing(fs.makeFolder(remote.path));
      return;
    }

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

    if (remote.kind === "doc") {
      this.remember(entry);
      const doc = this.doc(entry.id);
      if (!(await this.exchange(entry.id))) return;
      const text = doc.getText("content").toString();

      const here = (await fs.stat(remote.path)) ? normalize(await fs.readText(remote.path)) : text;
      if (here !== text && !(await this.superseded(remote, await textHash(here)))) {
        await this.pushLocal(await this.setAside(remote.path));
      }
      await this.writeBack(entry, text);
      return;
    }

    if (remote.blob_hash === null) return;
    if (this.tooLarge(remote.size)) {
      this.remember(entry);
      await this.persist(entry);
      return;
    }

    const here = (await fs.stat(remote.path)) ? await blobHash(await fs.readBinary(remote.path)) : remote.blob_hash;
    if (here !== remote.blob_hash && !(await this.superseded(remote, here))) {
      await this.pushLocal(await this.setAside(remote.path));
    }

    this.remember(entry);
    await this.download(entry, remote.blob_hash);
  }

  private async superseded(remote: Entry, hash: string): Promise<boolean> {
    try {
      const known = await this.vault!.knownVersion(remote.id, hash);
      if (known) this.emit("log", `${remote.path} here was an older version; taking the server's`);
      return known;
    } catch {
      return false;
    }
  }

  private async update(local: LocalEntry, remote: Entry): Promise<void> {
    const { fs } = this.options;

    if (remote.path !== local.path && !local.moved) {
      const recased = folded(remote.path) === folded(local.path);
      if (!recased) await this.vacate(remote.path);
      const left = local.path;
      const own = this.byPath.get(left) === local.id;
      const moved = own && (await fs.stat(left)) !== null;
      const alreadyThere = recased || (!moved && (await this.diskHash({ ...local, path: remote.path })) === local.hash);
      if (!alreadyThere && (await fs.stat(remote.path))) await this.pushLocal(await this.setAside(remote.path));
      if (moved) await placing(fs.rename(left, remote.path));
      if (own) this.byPath.delete(left);
      local.path = remote.path;
      this.byPath.set(local.path, local.id);
      await this.persist(local);

      if (local.kind === "folder") {
        await fs.makeFolder(local.path);
        await this.prune(left);
      } else if (moved) {
        await this.prune(parentOf(left));
      }
    }

    if (remote.kind === "doc" && local.kind === "blob") {
      const disk = await this.diskHash(local);
      if (disk !== null && disk !== local.hash) await this.pushLocal(await this.setAside(local.path));
      local.kind = "doc";
      local.hash = null;
      await this.persist(local);
    }

    const missing = local.kind !== "folder" && (await fs.stat(local.path)) === null;
    if (missing && local.hash !== null) return;

    if (remote.kind === "doc") {
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

    const kind = entry && entry.kind !== "folder" ? entry.kind : kindFor(path);

    if (kind === "doc") await this.pushText(path, entry);
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

    if (!this.sending) return;

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
      if (!(await this.exchange(fresh.id))) return;
      await this.record(fresh, hash);
    } catch (error) {
      if (!(error instanceof RequestError) || error.reason !== "exists" || !error.entry) throw error;
      await this.yieldTo(path, error.entry);
    }
  }

  private async pushBlob(path: string, entry: LocalEntry | undefined): Promise<void> {
    const { fs, client, vaultId } = this.options;
    const data = await fs.readBinary(path);
    const hash = await blobHash(data);

    if (entry && hash === entry.hash) return this.touch(entry);
    if (!this.sending) return;

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
      if (entry && this.gone(error)) return this.sendAsNew(entry);
      if (!(error instanceof RequestError) || !error.entry) throw error;
      if (error.reason !== "exists" && error.reason !== "conflict") throw error;
      await this.yieldTo(path, error.entry);
    }
  }

  private async yieldTo(path: string, holder: Entry): Promise<void> {
    if (holder.path !== path && !this.byPath.has(path)) {
      const mine = this.byId.get(holder.id);
      const files = mine ? await this.options.fs.list() : [];
      if (mine && !files.some((file) => file.path === mine.path)) return this.renameLocal(mine.path, path);
      await this.pushLocal(await this.setAside(path));
    }
    await this.applyRemote(holder);
    await this.mark(holder);
  }

  private async deleteLocal(path: string): Promise<void> {
    const id = this.byPath.get(path);
    const entry = id ? this.byId.get(id) : undefined;
    if (!entry || !this.sending) return;
    if (await this.options.fs.stat(path)) return;

    await this.drop(entry);
    await this.pushFolder(parentOf(path));
  }

  private async drop(entry: LocalEntry): Promise<void> {
    if (!this.sending) return;

    try {
      await this.vault!.remove(entry.id);
    } catch (error) {
      if (!this.gone(error)) throw error;
    }

    this.forget(entry);
    await this.discard(entry.id);
  }

  private async renameLocal(from: string, to: string): Promise<void> {
    const id = this.byPath.get(from);
    const entry = id ? this.byId.get(id) : undefined;
    if (!entry) return this.pushLocal(to);
    if (this.ignored(to)) return this.deleteLocal(from);

    const { fs } = this.options;
    const there = async (path: string) =>
      entry.kind === "folder" ? (await fs.folderState(path)) !== "missing" : (await fs.stat(path)) !== null;
    const left = !(await there(from)) || folded(from) === folded(to);
    const arrived = await there(to);
    const holder = this.byId.get(this.byPath.get(to) ?? "");
    const replaced = holder && holder.id !== entry.id ? holder : undefined;

    if (!left || !arrived || replaced) {
      if (entry.kind === "folder") return;
      await this.pushLocal(to);
      return left ? this.deleteLocal(from) : this.pushLocal(from);
    }

    this.byPath.delete(from);
    entry.path = to;
    entry.moved = true;
    this.byPath.set(to, entry.id);
    await this.persist(entry);
    if (this.sending) await this.pushRename(entry);
    if (entry.kind === "doc") await this.syncDoc(entry.id);
    await this.pushFolder(parentOf(from));
  }

  private async pushRename(entry: LocalEntry): Promise<void> {
    try {
      await this.vault!.rename(entry.id, entry.path);
    } catch (error) {
      if (this.gone(error)) return this.sendAsNew(entry);
      if (!(error instanceof RequestError) || error.reason !== "exists") throw error;
      if (entry.kind === "folder") {
        this.forget(entry);
        return this.discard(entry.id);
      }
      if (!(await this.options.fs.stat(entry.path))) return;
      const aside = await this.setAside(entry.path);
      this.byPath.delete(entry.path);
      entry.path = aside;
      this.byPath.set(aside, entry.id);
      await this.vault!.rename(entry.id, aside);
    }

    entry.moved = false;
    await this.persist(entry);
  }

  private async syncDoc(id: string): Promise<void> {
    const entry = this.byId.get(id);
    if (!entry || this.open.has(id)) return;

    await this.absorb(entry);
    if (this.online && !(await this.exchange(id, entry.dirty))) return;
    await this.settle(id);
  }

  private async exchange(id: string, announce = false): Promise<boolean> {
    const live = this.hold(id);
    if (!(await this.reached(id, live))) return false;

    try {
      if (announce && live.session.writable) await live.session.flush();
      const entry = this.byId.get(id);
      if (entry && live.session.writable) entry.dirty = false;
    } finally {
      this.release(id);
    }
    return true;
  }

  private async reached(id: string, live: Live): Promise<boolean> {
    try {
      await live.session.whenSynced();
      return true;
    } catch (error) {
      this.release(id);
      if (!(error instanceof Error) || error.message !== "not_found") throw error;
      this.retire(id, live);
      await this.lose(id);
      return false;
    }
  }

  private async lose(id: string): Promise<void> {
    const entry = this.byId.get(id);
    if (!entry) return;
    this.emit("log", `the server no longer has ${entry.path}`);
    if (!entry.dirty) return this.removeLocally(entry);
    await this.sendAsNew(entry);
  }

  private async sendAsNew(entry: LocalEntry): Promise<void> {
    this.forget(entry);
    await this.discard(entry.id);
    await this.pushLocal(entry.path);
  }

  private gone(error: unknown): boolean {
    return error instanceof RequestError && error.reason === "not_found";
  }

  private async settle(id: string): Promise<void> {
    const entry = this.byId.get(id);
    if (!entry || this.open.has(id)) return;

    const absorbed = await this.absorb(entry);
    if (absorbed && this.online && !(await this.exchange(id, true))) return;
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
    if (!file && entry.hash !== null) return;
    const disk = file ? normalize(await fs.readText(entry.path)) : null;
    if (disk !== text) await placing(fs.writeText(entry.path, text));
    await this.record(entry, await textHash(text));
  }

  private async download(entry: LocalEntry, hash: string): Promise<void> {
    const data = await this.options.client.download(this.options.vaultId, hash);
    await placing(this.options.fs.writeBinary(entry.path, data));
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
    await this.persist(entry);
  }

  private async setAside(path: string): Promise<string> {
    const { fs, device } = this.options;
    const stamped = conflictPath(path, device, (this.options.now ?? (() => new Date()))());
    let aside = stamped;
    for (let copy = 2; this.byPath.has(aside) || (await fs.stat(aside)); copy++) aside = numbered(stamped, copy);
    this.emit("log", `kept the copy of ${path} here as ${aside}`);
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
      await this.persist(holder);
      return;
    }

    const untouched = holder.kind !== "folder" && !holder.dirty && (await this.diskHash(holder)) === holder.hash;
    if (untouched && holder.hash !== null) await this.options.fs.remove(path);
    this.forget(holder);
    await this.discard(holder.id);
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

    live.timer = setTimeout(() => this.retire(id, live), this.options.sessionIdleMs ?? 30_000);

    const resting = [...this.live].filter(([, other]) => other.holds === 0);
    for (const [oldest, other] of resting.slice(0, -MAX_RESTING_SESSIONS)) this.retire(oldest, other);
  }

  private retire(id: string, live: Live): void {
    if (live.timer) clearTimeout(live.timer);
    live.timer = null;
    if (this.live.get(id) !== live) return;

    live.stop();
    live.session.close();
    this.live.delete(id);
    if (this.docs.size > 200 && !this.open.has(id)) this.docs.delete(id);
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
