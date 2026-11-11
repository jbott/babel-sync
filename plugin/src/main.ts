import { BabelSyncClient } from "@babelsync/core";
import { Notice, Platform, Plugin, TFile, TFolder, apiVersion, debounce, requestUrl } from "obsidian";
import { Collab } from "./collab.ts";
import { ConnectModal } from "./connect.ts";
import { type Progress, type Status, SyncEngine } from "./engine.ts";
import { IdbStore } from "./idb-store.ts";
import { type Invitation, readInvitation } from "./invitation.ts";
import { nativeFetch } from "./native-fetch.ts";
import {
  type Callback,
  type Pending,
  beginAuthorization,
  finishAuthorization,
  needsRefresh,
  refreshTokens,
  registerClient,
  revokeTokens,
} from "./oauth.ts";
import { ObsidianFs } from "./obsidian-fs.ts";
import { DEFAULT_SETTINGS, type RemoteVault, type Settings, SettingsTab, maxBlobBytes } from "./settings.ts";

const CONFIG_SCAN_MS = 30_000;
const TOKEN_CHECK_MS = 60_000;
const UPDATE_CHECK_MS = 60_000;
const DEVICE_ONLY = [/^\.obsidian\/workspace[^/]*\.json$/, /^\.obsidian\/plugins\/babelsync\/data\.json$/, /^\.obsidian\/cache$/, /^\.trash\//];

export type VaultsReply =
  | { kind: "vaults"; vaults: RemoteVault[] }
  | { kind: "signed-out" }
  | { kind: "failed"; message: string };

const LABELS: Record<Status, string> = {
  offline: "Babel Sync: offline",
  syncing: "Babel Sync: syncing",
  synced: "Babel Sync: synced",
  error: "Babel Sync: error",
};

declare const BABELSYNC_REVISION: string;

const MAX_JOURNAL_LINES = 400;

export default class BabelSyncPlugin extends Plugin {
  settings: Settings = { ...DEFAULT_SETTINGS };
  status: Status = "offline";
  onStatus: ((status: Status) => void) | null = null;
  build = "";
  revision = BABELSYNC_REVISION;
  updated = false;
  lastError = "";
  lastSynced: number | null = null;

  private client: BabelSyncClient | null = null;
  private engine: SyncEngine | null = null;
  private store: IdbStore | null = null;
  private fs!: ObsidianFs;
  private collab!: Collab;
  private statusBar: HTMLElement | null = null;
  private running = "";
  private transition: Promise<void> = Promise.resolve();
  private journal: string[] = [];

  async onload(): Promise<void> {
    this.settings = { ...DEFAULT_SETTINGS, ...((await this.loadData()) as Partial<Settings> | null) };
    this.fs = new ObsidianFs(this.app, () => this.settings.syncConfig);
    this.collab = new Collab(
      this.app,
      () => this.engine,
      () => ({ name: this.settings.userName || this.settings.deviceName, color: this.settings.userColor }),
    );

    this.statusBar = this.addStatusBarItem();
    this.show("offline");
    this.addSettingTab(new SettingsTab(this.app, this));
    this.registerEditorExtension(this.collab.extension);

    this.addCommand({ id: "resync", name: "Compare everything with the server again", callback: () => this.resync() });
    this.addCommand({ id: "reconnect", name: "Reconnect", callback: () => this.restart(true) });
    this.registerInterval(window.setInterval(() => void this.noticeUpdate(), UPDATE_CHECK_MS));
    void this.fingerprintOnDisk().then((build) => (this.build = build));

    this.registerEvent(this.app.vault.on("create", (file) => this.changed(file)));
    this.registerEvent(this.app.vault.on("modify", (file) => this.changed(file)));
    this.registerEvent(
      this.app.vault.on("delete", (file) => {
        if (file instanceof TFile) this.engine?.localDeleted(file.path);
        else this.engine?.localFolderDeleted(file.path);
      }),
    );
    this.registerEvent(
      this.app.vault.on("rename", (file, from) => {
        if (file instanceof TFile) this.engine?.localRenamed(from, file.path);
        else this.engine?.localFolderRenamed(from, file.path);
        this.rebind();
      }),
    );

    this.registerEvent(this.app.workspace.on("layout-change", () => this.rebind()));
    this.registerEvent(this.app.workspace.on("active-leaf-change", () => this.rebind()));
    this.registerInterval(window.setInterval(() => this.settings.syncConfig && this.engine?.rescan(), CONFIG_SCAN_MS));

    this.registerInterval(window.setInterval(() => void this.accessToken().catch(() => {}), TOKEN_CHECK_MS));
    this.registerDomEvent(document, "visibilitychange", () => {
      if (document.visibilityState === "visible") void this.accessToken().catch(() => {});
    });
    this.registerObsidianProtocolHandler("babelsync", ({ code, state, error }) => void this.finishSignIn({ code, state, error }));

    this.registerObsidianProtocolHandler("babelsync-connect", (params) => {
      const invitation = readInvitation(params);
      if (!invitation) return void new Notice("Babel Sync: that connect link is not valid.");
      new ConnectModal(this.app, this, invitation).open();
    });

    this.app.workspace.onLayoutReady(() => void this.restart());
  }

  async reload(): Promise<void> {
    const plugins = (this.app as unknown as { plugins: { disablePlugin(id: string): Promise<void>; enablePlugin(id: string): Promise<void> } }).plugins;
    await plugins.disablePlugin(this.manifest.id);
    await plugins.enablePlugin(this.manifest.id);
  }

  private async fingerprintOnDisk(): Promise<string> {
    try {
      const bytes = await this.app.vault.adapter.readBinary(`${this.manifest.dir}/main.js`);
      const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
      return [...digest.slice(0, 4)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
    } catch {
      return "";
    }
  }

  private async noticeUpdate(): Promise<void> {
    if (this.updated || !this.build) return;
    const onDisk = await this.fingerprintOnDisk();
    if (!onDisk || onDisk === this.build) return;

    this.updated = true;
    this.onStatus?.(this.status);
    new Notice("Babel Sync was updated. Open its settings and tap Reload to use the new version.", 15_000);
  }

  async adopt({ server, vaultId, vaultName }: Invitation): Promise<void> {
    const { tokens, serverUrl } = this.settings;

    if (serverUrl !== server && tokens) {
      this.settings.tokens = null;
      void revokeTokens(nativeFetch, serverUrl, tokens.refreshToken).catch(() => {});
    }

    if (this.settings.vaultId && (serverUrl !== server || this.settings.vaultId !== vaultId)) await this.forgetSyncState();

    Object.assign(this.settings, { serverUrl: server, vaultId, vaultName });
    await this.saveSettings();
    await this.restart();
  }

  async disconnect(): Promise<void> {
    await this.forgetSyncState();
    Object.assign(this.settings, { vaultId: "", vaultName: "" });
    await this.saveSettings();
    await this.restart(true);
  }

  private forgetSyncState(): Promise<void> {
    return this.serial(async () => {
      await this.halt();
      if (!this.settings.vaultId) return;
      const store = new IdbStore(this.storeName());
      await store.clear();
      await store.close();
    });
  }

  async remoteVaults(): Promise<VaultsReply> {
    const { serverUrl } = this.settings;
    if (!serverUrl) return { kind: "failed", message: "Enter the server address first." };

    try {
      const token = await this.accessToken();
      const response = await requestUrl({
        url: `${serverUrl}/api/vaults`,
        headers: token ? { authorization: `Bearer ${token}` } : {},
        throw: false,
      });

      if (response.status === 401) return { kind: "signed-out" };
      if (response.status !== 200) return { kind: "failed", message: `The server answered ${response.status}. Check the address.` };

      const vaults = (response.json as { vaults: RemoteVault[] }).vaults;
      await this.rememberName(vaults);
      return { kind: "vaults", vaults };
    } catch {
      return { kind: "failed", message: "Could not reach the server. Check the address and your connection." };
    }
  }

  private async rememberName(vaults: RemoteVault[]): Promise<void> {
    const name = vaults.find((vault) => vault.id === this.settings.vaultId)?.name;
    if (!name || name === this.settings.vaultName) return;
    this.settings.vaultName = name;
    await this.saveSettings();
  }

  async signIn(): Promise<void> {
    const url = await this.prepareSignIn();
    if (url) window.open(url);
  }

  async prepareSignIn(): Promise<string | null> {
    const { serverUrl, deviceName } = this.settings;

    if (!serverUrl) {
      new Notice("Enter the server address first.");
      return null;
    }

    try {
      this.settings.clientId = await registerClient(nativeFetch, serverUrl, `Obsidian (${deviceName})`);
      this.settings.clientServer = serverUrl;

      const { url, pending } = await beginAuthorization(serverUrl, this.settings.clientId);
      this.settings.pendingSignIn = pending;
      await this.saveSettings();
      return url;
    } catch (error) {
      new Notice(`Babel Sync: ${describe(error)}`);
      return null;
    }
  }

  async signOut(): Promise<void> {
    const { tokens, serverUrl } = this.settings;
    if (!tokens) return;

    this.settings.tokens = null;
    await this.saveSettings();
    await revokeTokens(nativeFetch, serverUrl, tokens.refreshToken).catch(() => {});
    await this.restart(true);
  }

  async accessToken(): Promise<string | undefined> {
    const { tokens, serverUrl, clientId } = this.settings;
    if (!tokens) return undefined;
    if (!needsRefresh(tokens)) return tokens.accessToken;

    this.refreshing ??= refreshTokens(nativeFetch, serverUrl, clientId, tokens.refreshToken)
      .then(async (fresh) => {
        this.settings.tokens = fresh;
        await this.saveSettings();
        if (!fresh) new Notice("Babel Sync was signed out. Sign in again from its settings.");
      })
      .finally(() => {
        this.refreshing = null;
      });

    await this.refreshing;
    return this.settings.tokens?.accessToken;
  }

  private refreshing: Promise<void> | null = null;

  private async finishSignIn(params: Callback): Promise<void> {
    const pending = this.settings.pendingSignIn;
    this.settings.pendingSignIn = null;
    if (!pending) return void new Notice("Babel Sync: no sign-in is in progress.");

    try {
      this.settings.tokens = await finishAuthorization(nativeFetch, pending, params);
      await this.saveSettings();
      new Notice("Babel Sync is signed in.");
      await this.restart(true);
    } catch (error) {
      await this.saveSettings();
      new Notice(`Babel Sync: ${describe(error)}`);
    }
  }

  onunload(): void {
    void this.shutdown();
  }

  async saveSettings(): Promise<void> {
    await this.saveData(this.settings);
  }

  restart(force = false): Promise<void> {
    return this.serial(async () => {
      const wanted = this.fingerprint();
      if (!force && wanted === this.running) return;
      await this.halt();
      await this.launch();
    });
  }

  resync(): Promise<void> {
    return this.serial(async () => {
      await this.halt();
      const store = new IdbStore(this.storeName());
      await store.clear();
      await store.close();
      await this.launch();
      new Notice("Babel Sync is comparing this vault with the server.");
    });
  }

  private shutdown(): Promise<void> {
    return this.serial(() => this.halt());
  }

  private serial(step: () => Promise<void>): Promise<void> {
    this.transition = this.transition.then(step).catch((error) => {
      console.error("Babel Sync", error);
      this.show("error");
    });
    return this.transition;
  }

  private async launch(): Promise<void> {
    const { serverUrl, vaultId, deviceName } = this.settings;
    this.running = this.fingerprint();
    if (!serverUrl || !vaultId) return this.show("offline");

    this.record(`connecting to ${serverUrl}, vault ${vaultId}`);
    await this.accessToken().catch(() => {});
    const client = new BabelSyncClient({
      baseUrl: serverUrl,
      token: () => this.settings.tokens?.accessToken,
      fetch: nativeFetch,
    });
    const store = new IdbStore(this.storeName());
    const engine = new SyncEngine({
      client,
      vaultId,
      store,
      fs: this.fs,
      device: deviceName,
      maxBlobBytes: maxBlobBytes(this.settings),
      ignore: (path) => this.ignored(path),
    });

    let cameOnline = false;
    engine.on("status", (status) => {
      this.show(status);
      if (status === "offline" || status === "error") cameOnline = false;
      if (status !== "synced" || cameOnline) return;
      cameOnline = true;
      this.rebind();
    });
    client.socket.onError(() => void this.accessToken().catch(() => {}));
    engine.on("log", (line) => this.record(line));
    engine.on("error", (reason) => {
      this.record(`error: ${reason}`);
      this.lastError = reason;
      new Notice(`Babel Sync: ${reason}`);
    });
    engine.on("progress", () => this.onStatus?.(this.status));

    this.client = client;
    this.store = store;
    this.engine = engine;

    client.connect();
    await engine.start();
    this.rebind();
  }

  private async halt(): Promise<void> {
    this.collab.releaseAll();
    await this.engine?.stop();
    await this.client?.disconnect();
    await this.store?.close();
    this.engine = null;
    this.client = null;
    this.store = null;
    this.running = "";
    this.show("offline");
  }

  private rebind = debounce(() => this.collab.refresh(), 50, true);

  private changed(file: unknown): void {
    if (file instanceof TFile) this.engine?.localChanged(file.path);
    else if (file instanceof TFolder) this.engine?.localFolderCreated(file.path);
  }

  private ignored(path: string): boolean {
    if (path.startsWith(".obsidian/") && !this.settings.syncConfig) return true;
    return DEVICE_ONLY.some((pattern) => pattern.test(path));
  }

  private fingerprint(): string {
    const { serverUrl, vaultId, deviceName, syncConfig, maxFileMebibytes } = this.settings;
    return JSON.stringify([serverUrl, vaultId, deviceName, syncConfig, maxFileMebibytes]);
  }

  private storeName(): string {
    return `babelsync-${this.app.vault.getName()}-${this.settings.vaultId}`;
  }

  get progress(): Progress | null {
    return this.engine?.progress ?? null;
  }

  get fileCount(): number {
    return this.engine?.fileCount ?? 0;
  }

  debugLog(): string {
    const { serverUrl, vaultId, vaultName, tokens } = this.settings;
    const device = Platform.isMobile ? (Platform.isIosApp ? "iOS" : "Android") : "desktop";

    return [
      `Babel Sync ${this.manifest.version}, commit ${this.revision}, build ${this.build || "unknown"}${this.updated ? " (newer build on disk)" : ""}`,
      `Obsidian ${apiVersion}, ${device}, ${navigator.userAgent}`,
      `server ${serverUrl || "not set"}, vault ${vaultName || "not chosen"} ${vaultId}`,
      `signed in: ${tokens !== null}, status: ${this.status}, files: ${this.fileCount}`,
      `last error: ${this.lastError || "none"}`,
      `last in sync: ${this.lastSynced ? new Date(this.lastSynced).toISOString() : "never"}`,
      "",
      ...this.journal,
    ].join("\n");
  }

  private record(line: string): void {
    this.journal.push(`${new Date().toISOString()} ${line}`);
    if (this.journal.length > MAX_JOURNAL_LINES) this.journal.shift();
  }

  private show(status: Status): void {
    if (status !== this.status) this.record(`status: ${status}`);
    this.status = status;
    if (status === "synced") {
      this.lastSynced = Date.now();
      this.lastError = "";
    }
    this.onStatus?.(status);
    this.statusBar?.setText(LABELS[status]);
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
