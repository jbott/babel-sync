import { type App, TFile, TFolder, normalizePath } from "obsidian";
import { type FileInfo, type FolderState, type VaultFs, parentOf } from "./fs.ts";

const SHARED_CONFIG = ".obsidian";

export class ObsidianFs implements VaultFs {
  private app: App;
  private includeConfig: () => boolean;

  constructor(app: App, includeConfig: () => boolean) {
    this.app = app;
    this.includeConfig = includeConfig;
  }

  toShared(local: string): string {
    const config = this.app.vault.configDir;
    if (local === config) return SHARED_CONFIG;
    return local.startsWith(config + "/") ? SHARED_CONFIG + local.slice(config.length) : local;
  }

  private toLocal(shared: string): string {
    const config = this.app.vault.configDir;
    const local = shared.startsWith(SHARED_CONFIG + "/") ? config + shared.slice(SHARED_CONFIG.length) : shared;
    return normalizePath(local);
  }

  async list(): Promise<FileInfo[]> {
    const files: FileInfo[] = this.app.vault.getFiles().map((file) => ({
      path: file.path,
      size: file.stat.size,
      mtime: file.stat.mtime,
    }));

    if (this.includeConfig()) await this.walk(this.app.vault.configDir, files);
    return files;
  }

  private async walk(folder: string, into: FileInfo[]): Promise<void> {
    const adapter = this.app.vault.adapter;
    if (!(await adapter.exists(folder))) return;
    const listing = await adapter.list(folder);

    for (const path of listing.files) {
      const stat = await adapter.stat(path);
      if (stat) into.push({ path: this.toShared(path), size: stat.size, mtime: stat.mtime });
    }
    for (const sub of listing.folders) await this.walk(sub, into);
  }

  async stat(path: string): Promise<FileInfo | null> {
    const stat = await this.app.vault.adapter.stat(this.toLocal(path));
    return stat && stat.type === "file" ? { path, size: stat.size, mtime: stat.mtime } : null;
  }

  async readText(path: string): Promise<string> {
    const file = this.file(path);
    return file ? this.app.vault.read(file) : this.app.vault.adapter.read(this.toLocal(path));
  }

  async writeText(path: string, text: string): Promise<void> {
    const file = this.file(path);
    if (file) return this.app.vault.modify(file, text);

    await this.ensureFolder(path);
    if (this.inConfig(path)) await this.app.vault.adapter.write(this.toLocal(path), text);
    else await this.app.vault.create(this.toLocal(path), text);
  }

  async readBinary(path: string): Promise<Uint8Array> {
    const file = this.file(path);
    const buffer = file ? await this.app.vault.readBinary(file) : await this.app.vault.adapter.readBinary(this.toLocal(path));
    return new Uint8Array(buffer);
  }

  async writeBinary(path: string, data: Uint8Array): Promise<void> {
    const buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
    const file = this.file(path);
    if (file) return this.app.vault.modifyBinary(file, buffer);

    await this.ensureFolder(path);
    if (this.inConfig(path)) await this.app.vault.adapter.writeBinary(this.toLocal(path), buffer);
    else await this.app.vault.createBinary(this.toLocal(path), buffer);
  }

  async remove(path: string): Promise<void> {
    const file = this.file(path);
    if (file) return this.app.fileManager.trashFile(file);

    const stat = await this.app.vault.adapter.stat(this.toLocal(path));
    if (stat?.type === "file") await this.app.vault.adapter.remove(this.toLocal(path));
  }

  async rename(from: string, to: string): Promise<void> {
    await this.ensureFolder(to);
    const file = this.file(from);
    if (file) await this.app.vault.rename(file, this.toLocal(to));
    else await this.app.vault.adapter.rename(this.toLocal(from), this.toLocal(to));
  }

  async folderState(folder: string): Promise<FolderState> {
    const adapter = this.app.vault.adapter;
    const local = this.toLocal(folder);
    const stat = await adapter.stat(local);
    if (!stat || stat.type !== "folder") return "missing";

    const listing = await adapter.list(local);
    return listing.files.length > 0 || listing.folders.length > 0 ? "occupied" : "empty";
  }

  async makeFolder(folder: string): Promise<void> {
    await this.ensureFolder(folder + "/placeholder");
  }

  async prune(folder: string, kept: (folder: string) => boolean): Promise<void> {
    const adapter = this.app.vault.adapter;
    const config = this.app.vault.configDir;
    const stops = (local: string) => local === "" || local === "/" || local === config || kept(this.toShared(local));

    for (let local = this.toLocal(folder); !stops(local); local = parentOf(local)) {
      if (!(await adapter.exists(local))) continue;

      const listing = await adapter.list(local);
      if (listing.files.length > 0 || listing.folders.length > 0) return;

      const known = this.app.vault.getAbstractFileByPath(local);
      if (known instanceof TFolder) await this.app.vault.delete(known, true);
      else await adapter.rmdir(local, true);
    }
  }

  async emptyFolders(): Promise<string[]> {
    const config = this.app.vault.configDir;

    return this.app.vault
      .getAllLoadedFiles()
      .filter((file): file is TFolder => file instanceof TFolder && !file.isRoot() && file.children.length === 0)
      .map((folder) => folder.path)
      .filter((path) => path !== config && !path.startsWith(config + "/") && !path.startsWith(".trash"));
  }

  private inConfig(path: string): boolean {
    return path.startsWith(SHARED_CONFIG + "/");
  }

  private file(path: string): TFile | null {
    if (this.inConfig(path)) return null;
    const found = this.app.vault.getAbstractFileByPath(this.toLocal(path));
    return found instanceof TFile ? found : null;
  }

  private async ensureFolder(path: string): Promise<void> {
    const local = this.toLocal(path);
    const slash = local.lastIndexOf("/");
    if (slash === -1) return;

    const folder = local.slice(0, slash);
    const adapter = this.app.vault.adapter;
    if (await adapter.exists(folder)) return;

    if (this.inConfig(path)) await adapter.mkdir(folder);
    else await this.app.vault.createFolder(folder).catch(() => {});
  }
}
