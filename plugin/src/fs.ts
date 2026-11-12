export type FileInfo = { path: string; size: number; mtime: number };

export function parentOf(path: string): string {
  const slash = path.lastIndexOf("/");
  return slash === -1 ? "" : path.slice(0, slash);
}

export type FolderState = "missing" | "empty" | "occupied";

export interface VaultFs {
  list(): Promise<FileInfo[]>;
  stat(path: string): Promise<FileInfo | null>;
  readText(path: string): Promise<string>;
  writeText(path: string, text: string): Promise<void>;
  readBinary(path: string): Promise<Uint8Array>;
  writeBinary(path: string, data: Uint8Array): Promise<void>;
  remove(path: string): Promise<void>;
  rename(from: string, to: string): Promise<void>;
  prune(folder: string, kept: (folder: string) => boolean): Promise<void>;
  folderState(folder: string): Promise<FolderState>;
  makeFolder(folder: string): Promise<void>;
  emptyFolders(): Promise<string[]>;
}

export type LocalEntry = {
  id: string;
  path: string;
  kind: "doc" | "blob" | "folder";
  hash: string | null;
  size: number;
  mtime: number;
  dirty: boolean;
  moved: boolean;
  doc?: Uint8Array;
  seq?: number;
  unwanted?: boolean;
};

export interface StateStore {
  load(): Promise<{ seq: number; entries: LocalEntry[] }>;
  put(entry: LocalEntry): Promise<void>;
  remove(id: string): Promise<void>;
  setSeq(seq: number): Promise<void>;
}

export class MemoryStore implements StateStore {
  seq = 0;
  entries = new Map<string, LocalEntry>();

  async load() {
    return { seq: this.seq, entries: [...this.entries.values()].map((entry) => ({ ...entry })) };
  }

  async put(entry: LocalEntry) {
    this.entries.set(entry.id, { ...entry });
  }

  async remove(id: string) {
    this.entries.delete(id);
  }

  async setSeq(seq: number) {
    this.seq = seq;
  }
}

export type FsEvent = { type: "changed" | "deleted" | "folderCreated"; path: string } | { type: "renamed"; from: string; path: string };

export class MemoryFs implements VaultFs {
  files = new Map<string, { data: Uint8Array; mtime: number }>();
  folders = new Set<string>();
  watcher: ((event: FsEvent) => void) | null = null;
  private clock = 1;
  private caseBlind: boolean;
  private refuses: (path: string) => boolean;

  constructor(options: { caseBlind?: boolean; refuses?: (path: string) => boolean } = {}) {
    this.caseBlind = options.caseBlind ?? false;
    this.refuses = options.refuses ?? (() => false);
  }

  private held(path: string): string {
    if (!this.caseBlind || this.files.has(path)) return path;
    const folded = path.toLowerCase();
    for (const name of this.files.keys()) if (name.toLowerCase() === folded) return name;
    return path;
  }

  private accept(path: string): void {
    if (this.refuses(path)) throw new Error(`the file name "${path}" is invalid`);
  }

  private tell(event: FsEvent): void {
    const { watcher } = this;
    if (watcher) queueMicrotask(() => watcher(event));
  }

  async list() {
    return [...this.files.entries()].map(([path, file]) => ({
      path,
      size: file.data.byteLength,
      mtime: file.mtime,
    }));
  }

  async stat(path: string) {
    const file = this.files.get(this.held(path));
    return file ? { path, size: file.data.byteLength, mtime: file.mtime } : null;
  }

  async readText(path: string) {
    return new TextDecoder().decode(await this.readBinary(path));
  }

  async writeText(path: string, text: string) {
    await this.writeBinary(path, new TextEncoder().encode(text));
  }

  async readBinary(path: string) {
    const file = this.files.get(this.held(path));
    if (!file) throw new Error(`no such file: ${path}`);
    return file.data;
  }

  async writeBinary(path: string, data: Uint8Array) {
    this.accept(path);
    const name = this.held(path);
    this.files.set(name, { data, mtime: this.clock++ });
    this.keepFolders(name);
    this.tell({ type: "changed", path: name });
  }

  async remove(path: string) {
    const name = this.held(path);
    if (this.files.delete(name)) this.tell({ type: "deleted", path: name });
  }

  async rename(from: string, to: string) {
    this.accept(to);
    const source = this.held(from);
    const file = this.files.get(source);
    if (!file) throw new Error(`no such file: ${from}`);
    this.files.delete(source);
    this.files.delete(this.held(to));
    this.files.set(to, file);
    this.keepFolders(to);
    this.tell({ type: "renamed", from: source, path: to });
  }

  async prune(folder: string, kept: (folder: string) => boolean) {
    for (let at = folder; at !== "" && !kept(at); at = parentOf(at)) {
      if (this.occupied(at)) return;
      this.folders.delete(at);
    }
  }

  async emptyFolders() {
    return [...this.folders].filter((folder) => !this.occupied(folder));
  }

  async folderState(folder: string): Promise<FolderState> {
    if (!this.folders.has(folder)) return "missing";
    return this.occupied(folder) ? "occupied" : "empty";
  }

  async makeFolder(folder: string) {
    const fresh = !this.folders.has(folder);
    this.keepFolders(folder + "/");
    if (fresh) this.tell({ type: "folderCreated", path: folder });
  }

  private occupied(folder: string): boolean {
    return [...this.files.keys(), ...this.folders].some((path) => path.startsWith(folder + "/"));
  }

  private keepFolders(path: string) {
    for (let at = parentOf(path); at !== ""; at = parentOf(at)) this.folders.add(at);
  }
}
