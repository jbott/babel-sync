export type FileInfo = { path: string; size: number; mtime: number };

export interface VaultFs {
  list(): Promise<FileInfo[]>;
  stat(path: string): Promise<FileInfo | null>;
  readText(path: string): Promise<string>;
  writeText(path: string, text: string): Promise<void>;
  readBinary(path: string): Promise<Uint8Array>;
  writeBinary(path: string, data: Uint8Array): Promise<void>;
  remove(path: string): Promise<void>;
  rename(from: string, to: string): Promise<void>;
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

export class MemoryFs implements VaultFs {
  files = new Map<string, { data: Uint8Array; mtime: number }>();
  private clock = 1;

  async list() {
    return [...this.files.entries()].map(([path, file]) => ({
      path,
      size: file.data.byteLength,
      mtime: file.mtime,
    }));
  }

  async stat(path: string) {
    const file = this.files.get(path);
    return file ? { path, size: file.data.byteLength, mtime: file.mtime } : null;
  }

  async readText(path: string) {
    return new TextDecoder().decode(await this.readBinary(path));
  }

  async writeText(path: string, text: string) {
    await this.writeBinary(path, new TextEncoder().encode(text));
  }

  async readBinary(path: string) {
    const file = this.files.get(path);
    if (!file) throw new Error(`no such file: ${path}`);
    return file.data;
  }

  async writeBinary(path: string, data: Uint8Array) {
    this.files.set(path, { data, mtime: this.clock++ });
  }

  async remove(path: string) {
    this.files.delete(path);
  }

  async rename(from: string, to: string) {
    const file = this.files.get(from);
    if (!file) throw new Error(`no such file: ${from}`);
    this.files.delete(from);
    this.files.set(to, file);
  }
}
