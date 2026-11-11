import { BabelSyncClient } from "@babelsync/core";
import { Notice, Plugin, TFile, debounce } from "obsidian";
import { Collab } from "./collab.ts";
import { type Status, SyncEngine } from "./engine.ts";
import { IdbStore } from "./idb-store.ts";
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
import { DEFAULT_SETTINGS, type Settings, SettingsTab, maxBlobBytes } from "./settings.ts";

const CONFIG_SCAN_MS = 30_000;
const TOKEN_CHECK_MS = 60_000;
const DEVICE_ONLY = [/^\.obsidian\/workspace[^/]*\.json$/, /^\.obsidian\/plugins\/babelsync\/data\.json$/, /^\.obsidian\/cache$/, /^\.trash\//];

const LABELS: Record<Status, string> = {
  offline: "BabelSync: offline",
  syncing: "BabelSync: syncing",
  synced: "BabelSync: synced",
  error: "BabelSync: error",
};

export default class BabelSyncPlugin extends Plugin {
  settings: Settings = { ...DEFAULT_SETTINGS };

  private client: BabelSyncClient | null = null;
  private engine: SyncEngine | null = null;
  private store: IdbStore | null = null;
  private fs!: ObsidianFs;
  private collab!: Collab;
  private statusBar: HTMLElement | null = null;
  private running = "";
  private transition: Promise<void> = Promise.resolve();

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

    this.registerEvent(this.app.vault.on("create", (file) => this.changed(file)));
    this.registerEvent(this.app.vault.on("modify", (file) => this.changed(file)));
    this.registerEvent(this.app.vault.on("delete", (file) => file instanceof TFile && this.engine?.localDeleted(file.path)));
    this.registerEvent(
      this.app.vault.on("rename", (file, from) => {
        if (file instanceof TFile) this.engine?.localRenamed(from, file.path);
        this.rebind();
      }),
    );

    this.registerEvent(this.app.workspace.on("layout-change", () => this.rebind()));
    this.registerEvent(this.app.workspace.on("active-leaf-change", () => this.rebind()));
    this.registerInterval(window.setInterval(() => this.settings.syncConfig && this.engine?.rescan(), CONFIG_SCAN_MS));

    this.registerInterval(window.setInterval(() => void this.accessToken().catch(() => {}), TOKEN_CHECK_MS));
    this.registerObsidianProtocolHandler("babelsync", ({ code, state, error }) => void this.finishSignIn({ code, state, error }));

    this.app.workspace.onLayoutReady(() => void this.restart());
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
      if (!this.settings.clientId || this.settings.clientServer !== serverUrl) {
        this.settings.clientId = await registerClient(nativeFetch, serverUrl, `Obsidian (${deviceName})`);
        this.settings.clientServer = serverUrl;
      }

      const { url, pending } = await beginAuthorization(serverUrl, this.settings.clientId);
      this.settings.pendingSignIn = pending;
      await this.saveSettings();
      return url;
    } catch (error) {
      new Notice(`BabelSync: ${describe(error)}`);
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
        if (!fresh) new Notice("BabelSync was signed out. Sign in again from its settings.");
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
    if (!pending) return void new Notice("BabelSync: no sign-in is in progress.");

    try {
      this.settings.tokens = await finishAuthorization(nativeFetch, pending, params);
      await this.saveSettings();
      new Notice("BabelSync is signed in.");
      await this.restart(true);
    } catch (error) {
      await this.saveSettings();
      new Notice(`BabelSync: ${describe(error)}`);
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
      new Notice("BabelSync is comparing this vault with the server.");
    });
  }

  private shutdown(): Promise<void> {
    return this.serial(() => this.halt());
  }

  private serial(step: () => Promise<void>): Promise<void> {
    this.transition = this.transition.then(step).catch((error) => {
      console.error("BabelSync", error);
      this.show("error");
    });
    return this.transition;
  }

  private async launch(): Promise<void> {
    const { serverUrl, vaultId, deviceName } = this.settings;
    this.running = this.fingerprint();
    if (!serverUrl || !vaultId) return this.show("offline");

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

    engine.on("status", (status) => this.show(status));
    engine.on("error", (reason) => new Notice(`BabelSync: ${reason}`));

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

  private show(status: Status): void {
    this.statusBar?.setText(LABELS[status]);
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
