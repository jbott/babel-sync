import type { Against, BabelSyncClient, ChangedLine, VersionDetail, VersionSummary } from "@babelsync/core";
import { ItemView, Notice, type TFile, type WorkspaceLeaf, debounce } from "obsidian";

export const HISTORY_VIEW = "babelsync-history";

export type HistorySource = {
  client(): BabelSyncClient | null;
  vaultId(): string;
  noteId(path: string): string | undefined;
};

type Mode = Against | "text";

const MODES: [Mode, string][] = [
  ["previous", "Changes"],
  ["now", "Since then"],
  ["text", "Text"],
];

const CONFIRM_MS = 4000;
const SETTLED_MS = 35_000;

export class HistoryView extends ItemView {
  private file: TFile | null = null;
  private versions: VersionSummary[] = [];
  private chosen: VersionSummary | null = null;
  private detail: VersionDetail | null = null;
  private mode: Mode = "previous";
  private message = "";
  private generation = 0;
  private confirming = false;
  private refreshSoon = debounce(() => !this.chosen && void this.refresh(), SETTLED_MS, true);

  private source: HistorySource;

  constructor(leaf: WorkspaceLeaf, source: HistorySource) {
    super(leaf);
    this.source = source;
  }

  getViewType(): string {
    return HISTORY_VIEW;
  }

  getDisplayText(): string {
    return "Version history";
  }

  getIcon(): string {
    return "history";
  }

  async onOpen(): Promise<void> {
    this.contentEl.addClass("babelsync-history");
    this.addAction("refresh-cw", "Refresh", () => void this.refresh());
    this.registerEvent(this.app.workspace.on("file-open", (file) => file && void this.follow(file)));
    this.registerEvent(this.app.vault.on("modify", (file) => file.path === this.file?.path && this.refreshSoon()));
    await this.follow(this.app.workspace.getActiveFile());
  }

  async onClose(): Promise<void> {
    this.refreshSoon.cancel();
  }

  async follow(file: TFile | null, again = false): Promise<void> {
    if (!file || (!again && file.path === this.file?.path)) return;
    this.file = file;
    this.chosen = null;
    this.detail = null;
    this.mode = "previous";
    await this.refresh();
  }

  async refresh(): Promise<void> {
    const generation = ++this.generation;
    const target = this.target();
    this.message = "Loading…";
    this.render();

    if (typeof target === "string") {
      this.message = target;
      this.versions = [];
      return this.render();
    }

    try {
      const versions = await target.client.versions(target.vaultId, target.id);
      if (generation !== this.generation) return;
      this.versions = versions;
      this.message = versions.length ? "" : "No saved versions yet. Versions are kept about half a minute after editing stops.";
      this.chosen = versions.find((version) => version.id === this.chosen?.id) ?? null;
      if (this.chosen) return this.choose(this.chosen, this.mode);
    } catch {
      if (generation !== this.generation) return;
      this.versions = [];
      this.message = "Could not load the history from the server.";
    }
    this.render();
  }

  private target(): { client: BabelSyncClient; vaultId: string; id: string } | string {
    if (!this.file) return "Open a note to see its history.";
    const client = this.source.client();
    if (!client) return "Babel Sync is not connected.";
    const id = this.source.noteId(this.file.path);
    if (!id) return "This file has no text history on the server.";
    return { client, vaultId: this.source.vaultId(), id };
  }

  private async choose(version: VersionSummary, mode: Mode): Promise<void> {
    const generation = ++this.generation;
    const target = this.target();
    if (typeof target === "string") return;

    this.chosen = version;
    this.mode = mode;
    this.confirming = false;
    this.render();

    try {
      const detail = await target.client.version(target.vaultId, target.id, version.id, mode === "now" ? "now" : "previous");
      if (generation !== this.generation) return;
      this.detail = detail;
    } catch {
      if (generation !== this.generation) return;
      this.detail = null;
      new Notice("Babel Sync: could not load that version.");
    }
    this.render();
  }

  private async restore(version: VersionSummary): Promise<void> {
    if (!this.confirming) {
      this.confirming = true;
      this.render();
      window.setTimeout(() => {
        if (!this.confirming) return;
        this.confirming = false;
        this.render();
      }, CONFIRM_MS);
      return;
    }

    const target = this.target();
    if (typeof target === "string") return;
    this.confirming = false;
    try {
      await target.client.restore(target.vaultId, target.id, version.id);
      new Notice(`Babel Sync: restored the version from ${when(version.saved_at)}.`);
      this.chosen = null;
      this.detail = null;
      await this.refresh();
    } catch {
      new Notice("Babel Sync: could not restore that version.");
      this.render();
    }
  }

  private render(): void {
    const root = this.contentEl;
    root.empty();

    const head = root.createDiv({ cls: "babelsync-history-head" });
    head.createDiv({ cls: "babelsync-history-file", text: this.file?.basename ?? "" });
    if (this.message) root.createDiv({ cls: "babelsync-history-message", text: this.message });

    const list = root.createDiv({ cls: ["babelsync-history-list", this.chosen ? "is-short" : ""] });
    let day = "";
    for (const version of this.versions) {
      const label = dayOf(version.saved_at);
      if (label !== day) list.createDiv({ cls: "babelsync-history-day", text: (day = label) });

      const row = list.createEl("button", { cls: ["babelsync-history-version", version.id === this.chosen?.id ? "is-chosen" : ""] });
      row.addEventListener("click", () => void this.choose(version, this.mode));
      const left = row.createDiv({ cls: "babelsync-history-when" });
      left.createSpan({ text: timeOf(version.saved_at) });
      if (version.author) left.createSpan({ cls: "babelsync-history-author", text: version.author });
      counts(row.createDiv({ cls: "babelsync-history-counts" }), version.added, version.removed, version.bytes);
    }

    if (this.chosen) this.renderDetail(root, this.chosen);
  }

  private renderDetail(root: HTMLElement, version: VersionSummary): void {
    const pane = root.createDiv({ cls: "babelsync-history-detail" });
    const bar = pane.createDiv({ cls: "babelsync-history-bar" });
    const modes = bar.createDiv({ cls: "babelsync-history-modes" });
    for (const [mode, label] of MODES) {
      const button = modes.createEl("button", { text: label, cls: mode === this.mode ? "is-active" : "" });
      button.addEventListener("click", () => void this.choose(version, mode));
    }

    const detail = this.detail?.id === version.id ? this.detail : null;
    if (!detail) return void pane.createDiv({ cls: "babelsync-history-message", text: "Loading…" });

    if (this.mode !== "text") counts(bar.createDiv({ cls: "babelsync-history-counts" }), detail.changes.added, detail.changes.removed, null);

    const caption =
      this.mode === "now"
        ? "From this version to the note as it is now."
        : this.mode === "previous"
          ? version.earliest
            ? "The earliest kept version, compared with an empty note."
            : "What this version changed from the one before it."
          : "";
    if (caption) pane.createDiv({ cls: "babelsync-history-caption", text: caption });

    const body = pane.createDiv({ cls: "babelsync-history-body" });
    if (this.mode === "text") body.createEl("pre", { cls: "babelsync-history-text", text: detail.text });
    else if (!detail.changes.hunks.length) body.createDiv({ cls: "babelsync-history-message", text: "No differences." });
    else
      for (const hunk of detail.changes.hunks) {
        const block = body.createDiv({ cls: "babelsync-history-hunk" });
        block.createDiv({ cls: "babelsync-history-hunk-head", text: `Line ${hunk.new_start}` });
        for (const line of hunk.lines) renderLine(block, line);
      }

    const restore = pane.createEl("button", {
      cls: ["babelsync-history-restore", this.confirming ? "mod-warning" : "mod-cta"],
      text: this.confirming ? "Tap again to replace the note with this version" : "Restore this version",
    });
    restore.addEventListener("click", () => void this.restore(version));
  }
}

function renderLine(parent: HTMLElement, line: ChangedLine): void {
  const row = parent.createDiv({ cls: ["babelsync-history-line", `is-${line.kind}`] });
  row.createSpan({ cls: "babelsync-history-number", text: String(line.new ?? line.old ?? "") });
  row.createSpan({ cls: "babelsync-history-marker", text: line.kind === "added" ? "+" : line.kind === "removed" ? "−" : "" });
  const text = row.createSpan({ cls: "babelsync-history-content" });
  const whole = line.segments.length === 1;
  for (const [kind, piece] of line.segments) text.createSpan({ cls: whole || kind === "same" ? "" : `is-${kind}`, text: piece });
  if (line.segments.every(([, piece]) => piece === "")) text.setText(" ");
}

function counts(parent: HTMLElement, added: number | null, removed: number | null, bytes: number | null): void {
  if (added) parent.createSpan({ cls: "is-added", text: `+${added}` });
  if (removed) parent.createSpan({ cls: "is-removed", text: `−${removed}` });
  if (!added && !removed && bytes !== null) parent.createSpan({ cls: "is-size", text: size(bytes) });
}

function size(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function dayOf(iso: string): string {
  const date = new Date(iso);
  const today = new Date();
  const yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1);
  if (date.toDateString() === today.toDateString()) return "Today";
  if (date.toDateString() === yesterday.toDateString()) return "Yesterday";
  return date.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short", year: "numeric" });
}

function timeOf(iso: string): string {
  return new Date(iso).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

function when(iso: string): string {
  return `${dayOf(iso).toLowerCase()} at ${timeOf(iso)}`;
}

export const HISTORY_STYLE = `
.babelsync-history { display: flex; flex-direction: column; padding: 0 !important; }
.babelsync-history-head { padding: var(--size-4-3) var(--size-4-3) var(--size-4-2); font-weight: var(--font-semibold); }
.babelsync-history-message { padding: var(--size-4-3); color: var(--text-muted); font-size: var(--font-ui-small); }
.babelsync-history-list { overflow-y: auto; flex: 1 1 auto; padding: 0 var(--size-4-2) var(--size-4-2); }
.babelsync-history-list.is-short { flex: 0 0 auto; max-height: 30%; border-bottom: 1px solid var(--background-modifier-border); }
.babelsync-history-day { padding: var(--size-4-2) var(--size-4-2) var(--size-4-1); color: var(--text-faint); font-size: var(--font-ui-smaller); text-transform: uppercase; letter-spacing: 0.06em; }
.babelsync-history-version { display: flex; width: 100%; height: auto; align-items: center; justify-content: space-between; gap: var(--size-4-2); padding: var(--size-4-1) var(--size-4-2); background: none; box-shadow: none; border-radius: var(--radius-s); font-size: var(--font-ui-small); text-align: left; cursor: pointer; }
.babelsync-history-version:hover { background: var(--background-modifier-hover); }
.babelsync-history-version.is-chosen { background: var(--background-modifier-active-hover); }
.babelsync-history-when { display: flex; flex-direction: column; min-width: 0; }
.babelsync-history-author { color: var(--text-faint); font-size: var(--font-ui-smaller); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.babelsync-history-counts { display: flex; gap: var(--size-4-1); font-size: var(--font-ui-smaller); font-variant-numeric: tabular-nums; white-space: nowrap; }
.babelsync-history-counts .is-added { color: var(--color-green); }
.babelsync-history-counts .is-removed { color: var(--color-red); }
.babelsync-history-counts .is-size { color: var(--text-faint); }
.babelsync-history-detail { display: flex; flex-direction: column; flex: 1 1 0; min-height: 0; }
.babelsync-history-bar { display: flex; align-items: center; justify-content: space-between; gap: var(--size-4-2); padding: var(--size-4-2) var(--size-4-3); }
.babelsync-history-modes { display: inline-flex; padding: 2px; border-radius: var(--radius-m); background: var(--background-modifier-hover); }
.babelsync-history-modes button { height: auto; padding: var(--size-4-1) var(--size-4-2); background: none; box-shadow: none; font-size: var(--font-ui-smaller); color: var(--text-muted); }
.babelsync-history-modes button.is-active { background: var(--background-primary); color: var(--text-normal); box-shadow: var(--shadow-s); }
.babelsync-history-caption { padding: 0 var(--size-4-3) var(--size-4-2); color: var(--text-faint); font-size: var(--font-ui-smaller); }
.babelsync-history-body { flex: 1 1 0; min-height: 0; overflow: auto; font-family: var(--font-monospace); font-size: var(--font-ui-smaller); line-height: 1.55; user-select: text; }
.babelsync-history-text { margin: 0; padding: var(--size-4-3); white-space: pre-wrap; word-break: break-word; }
.babelsync-history-hunk { margin-bottom: var(--size-4-2); border-top: 1px solid var(--background-modifier-border); border-bottom: 1px solid var(--background-modifier-border); }
.babelsync-history-hunk-head { padding: 1px var(--size-4-3); background: var(--background-secondary); color: var(--text-faint); font-family: var(--font-interface); }
.babelsync-history-line { display: flex; }
.babelsync-history-line.is-added { background: rgba(var(--color-green-rgb), 0.1); }
.babelsync-history-line.is-removed { background: rgba(var(--color-red-rgb), 0.1); }
.babelsync-history-line.is-same .babelsync-history-content { color: var(--text-muted); }
.babelsync-history-number { flex: 0 0 2.6em; padding-right: 0.5em; text-align: right; color: var(--text-faint); user-select: none; }
.babelsync-history-marker { flex: 0 0 1.2em; user-select: none; }
.is-added > .babelsync-history-marker { color: var(--color-green); }
.is-removed > .babelsync-history-marker { color: var(--color-red); }
.babelsync-history-content { flex: 1; min-width: 0; padding-right: var(--size-4-3); white-space: pre-wrap; word-break: break-word; }
.babelsync-history-content .is-added { background: rgba(var(--color-green-rgb), 0.28); border-radius: 2px; }
.babelsync-history-content .is-removed { background: rgba(var(--color-red-rgb), 0.28); border-radius: 2px; text-decoration: line-through; text-decoration-color: rgba(var(--color-red-rgb), 0.5); }
.babelsync-history-restore { margin: var(--size-4-2) var(--size-4-3) calc(var(--size-4-3) + env(safe-area-inset-bottom, 0px)); }
body:not(.is-mobile) .babelsync-history-restore { margin-bottom: calc(var(--size-4-3) + 2rem); }
`;
