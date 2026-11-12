import { BabelSyncClient } from "@babelsync/core";
import { Notice, Platform, Plugin, TFile, TFolder, apiVersion, debounce, requestUrl } from "obsidian";
import { Collab } from "./collab.ts";
import { ConnectModal, VaultPickerModal } from "./connect.ts";
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

const CONFIG_SCAN_MS = Platform.isMobile ? 300_000 : 60_000;
const TOKEN_CHECK_MS = 60_000;
const UPDATE_FETCH_MS = 3_600_000;
const UPDATE_FETCH_AFTER_MS = 600_000;
const AWAY_MS = 20_000;
const SHIPPED = ["manifest.json", "main.js"];
const PASSING = /^(timed out waiting for (synced|joined)|timeout)$/;
const CURSOR_COLORS = ["#7c3aed", "#2563eb", "#0891b2", "#059669", "#ca8a04", "#ea580c", "#dc2626", "#db2777"];
const DEVICE_ONLY = [/^\.obsidian\/workspace[^/]*\.json$/, /^\.obsidian\/plugins\/babelsync\//, /^\.obsidian\/cache$/, /^\.trash\//];

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

const MAX_JOURNAL_LINES = 600;
const JOURNAL_SAVE_MS = 1_000;

export default class BabelSyncPlugin extends Plugin {
  settings: Settings = { ...DEFAULT_SETTINGS };
  status: Status = "offline";
  onStatus: ((status: Status) => void) | null = null;
  build = "";
  revision = BABELSYNC_REVISION;
  updated = false;
  private fetching = false;
  private lastFetched = 0;
  private hiddenAt = 0;
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
  private journalSave: number | null = null;
  private instance = Math.random().toString(16).slice(2, 6);
  private retired = false;
  private release: (() => void) | null = null;

  async onload(): Promise<void> {
    this.restoreJournal();
    this.record(`plugin loaded, commit ${this.revision}`);
    this.claimVault();
    this.settings = { ...DEFAULT_SETTINGS, ...((await this.loadData()) as Partial<Settings> | null) };
    this.fs = new ObsidianFs(this.app, () => this.settings.syncConfig);
    this.collab = new Collab(
      this.app,
      () => this.engine,
      () => this.presence(),
    );

    this.statusBar = this.addStatusBarItem();
    this.show("offline");
    this.addSettingTab(new SettingsTab(this.app, this));
    this.registerEditorExtension(this.collab.extension);

    this.addCommand({ id: "verify", name: "Verify this vault against the server", callback: () => this.verify() });
    this.addCommand({ id: "reconnect", name: "Reconnect", callback: () => this.restart(true) });
    this.registerInterval(window.setInterval(() => void this.fetchUpdate(), UPDATE_FETCH_MS));
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
    this.registerInterval(window.setInterval(() => this.visible() && this.scanConfig(), CONFIG_SCAN_MS));

    this.registerInterval(window.setInterval(() => void this.accessToken().catch(() => {}), TOKEN_CHECK_MS));
    this.registerDomEvent(document, "visibilitychange", () => {
      if (!this.visible()) {
        this.hiddenAt = Date.now();
        return this.scanConfig();
      }
      void this.accessToken().catch(() => {});
      if (this.hiddenAt && Date.now() - this.hiddenAt > AWAY_MS) {
        this.client?.probe();
        this.scanConfig();
      }
      this.hiddenAt = 0;
    });
    this.registerObsidianProtocolHandler("babelsync", ({ code, state, error }) => void this.finishSignIn({ code, state, error }));

    this.registerObsidianProtocolHandler("babelsync-connect", (params) => {
      const invitation = readInvitation(params);
      if (!invitation) return void this.notify("Babel Sync: that connect link is not valid.");
      new ConnectModal(this.app, this, invitation).open();
    });

    this.addCommand({ id: "reload", name: "Reload plugin", callback: () => void this.reload() });
    this.addCommand({
      id: "copy-debug-log",
      name: "Copy debug log",
      callback: async () => {
        await navigator.clipboard.writeText(this.debugLog());
        this.notify("Babel Sync: debug log copied.");
      },
    });

    this.app.workspace.onLayoutReady(() => void this.restart());
  }

  async reload(): Promise<void> {
    const plugins = (this.app as unknown as { plugins: { disablePlugin(id: string): Promise<void>; enablePlugin(id: string): Promise<void> } }).plugins;
    await plugins.disablePlugin(this.manifest.id);
    await plugins.enablePlugin(this.manifest.id);
  }

  private async buildOf(bytes: ArrayBuffer): Promise<string> {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
    return [...digest.slice(0, 4)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  }

  private async fingerprintOnDisk(): Promise<string> {
    try {
      return await this.buildOf(await this.app.vault.adapter.readBinary(`${this.manifest.dir}/main.js`));
    } catch {
      return "";
    }
  }

  private async fromServer(path: string) {
    const token = await this.accessToken();
    const response = await requestUrl({
      url: `${this.settings.serverUrl}/api/plugin${path}`,
      headers: token ? { authorization: `Bearer ${token}` } : {},
      throw: false,
    });
    if (response.status !== 200) throw new Error(`the server answered ${response.status} for the plugin${path}`);
    return response;
  }

  private visible(): boolean {
    return document.visibilityState === "visible";
  }

  private scanConfig(): void {
    if (this.settings.syncConfig) this.engine?.rescan();
  }

  private async fetchUpdate(force = true): Promise<void> {
    if (this.fetching || this.updated || !this.build || !this.settings.serverUrl) return;
    if (!force && Date.now() - this.lastFetched < UPDATE_FETCH_AFTER_MS) return;
    this.fetching = true;
    this.lastFetched = Date.now();

    try {
      const { build } = (await this.fromServer("")).json as { build: string | null };
      if (!build || build === this.build) return;

      if ((await this.fingerprintOnDisk()) !== build) {
        const files = new Map<string, ArrayBuffer>();
        for (const name of SHIPPED) files.set(name, (await this.fromServer(`/${name}`)).arrayBuffer);
        const received = await this.buildOf(files.get("main.js")!);
        if (received !== build) throw new Error(`the server promised build ${build} and sent ${received}`);

        for (const [name, bytes] of files) await this.app.vault.adapter.writeBinary(`${this.manifest.dir}/${name}`, bytes);
        this.record(`fetched build ${build} from the server to replace ${this.build}`);
      }
      await this.noticeUpdate();
    } catch (error) {
      this.record(`could not fetch the plugin: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      this.fetching = false;
    }
  }

  private async noticeUpdate(): Promise<void> {
    if (this.updated || !this.build) return;
    const onDisk = await this.fingerprintOnDisk();
    if (!onDisk || onDisk === this.build) return;

    this.updated = true;
    this.onStatus?.(this.status);
    this.notify("Babel Sync was updated. Tap here to reload it and use the new version.", 30_000, () => void this.reload());
  }

  async adopt({ server, vaultId, vaultName }: Invitation): Promise<void> {
    const { tokens, serverUrl } = this.settings;

    if (serverUrl !== server && tokens) {
      this.settings.tokens = null;
      void revokeTokens(nativeFetch, serverUrl, tokens.refreshToken).catch(() => {});
    }

    if (this.settings.vaultId && (serverUrl !== server || this.settings.vaultId !== vaultId)) await this.forgetSyncState();

    if (this.settings.vaultId !== vaultId) this.settings.storeName = "";
    Object.assign(this.settings, { serverUrl: server, vaultId, vaultName });
    await this.saveSettings();
    await this.restart();
  }

  async disconnect(): Promise<void> {
    await this.forgetSyncState();
    Object.assign(this.settings, { vaultId: "", vaultName: "", storeName: "" });
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

  async chooseVault(): Promise<void> {
    const reply = await this.remoteVaults();
    if (reply.kind === "signed-out") return void this.notify("Babel Sync: sign in first.");
    if (reply.kind === "failed") return void this.notify(`Babel Sync: ${reply.message}`);

    const server = this.settings.serverUrl;
    const confirm = (vault: RemoteVault) =>
      new ConnectModal(this.app, this, { server, vaultId: vault.id, vaultName: vault.name, files: vault.files }).open();

    if (reply.vaults.length === 0) {
      this.notify("Babel Sync: there are no vaults on the server yet. Create one in the web app, then choose a vault from the plugin's settings.", 12_000);
    } else if (reply.vaults.length === 1) {
      confirm(reply.vaults[0]);
    } else {
      new VaultPickerModal(this.app, reply.vaults, confirm).open();
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
      this.notify("Enter the server address first.");
      return null;
    }

    try {
      this.settings.clientId = await registerClient(nativeFetch, serverUrl, deviceName || "Obsidian");
      this.settings.clientServer = serverUrl;

      const { url, pending } = await beginAuthorization(serverUrl, this.settings.clientId);
      this.settings.pendingSignIn = pending;
      await this.saveSettings();
      return url;
    } catch (error) {
      this.notify(`Babel Sync: ${describe(error)}`);
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
        const saved = fresh ? null : ((await this.loadData()) as Partial<Settings> | null)?.tokens;
        if (saved && saved.refreshToken !== tokens.refreshToken) {
          this.settings.tokens = saved;
          this.record("the saved sign-in was newer than the one in use; using it");
          return;
        }
        this.settings.tokens = fresh;
        await this.saveSettings();
        this.record(fresh ? "sign-in renewed" : "the server refused to renew the sign-in; signed out");
        if (!fresh) this.notify("Babel Sync was signed out. Sign in again from its settings.");
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
    if (!pending) return void this.notify("Babel Sync: no sign-in is in progress.");

    try {
      this.settings.tokens = await finishAuthorization(nativeFetch, pending, params);
      await this.saveSettings();
      this.notify("Babel Sync is signed in.");
      await this.restart(true);
      if (!this.settings.vaultId) await this.chooseVault();
    } catch (error) {
      await this.saveSettings();
      this.notify(`Babel Sync: ${describe(error)}`);
    }
  }

  onunload(): void {
    this.record("plugin unloaded");
    this.retire();
    this.release?.();
  }

  private claimVault(): void {
    const locks = (navigator as Navigator & { locks?: LockManager }).locks;
    if (!locks) return;

    const held = new Promise<void>((resolve) => (this.release = resolve));
    locks.request(`babelsync:${this.vaultKey()}`, { steal: true }, () => held).catch(() => {
      if (this.retired) return;
      this.record("another copy of the plugin took over this vault; this one has stopped");
      this.retire();
    });
  }

  private retire(): void {
    this.retired = true;
    this.saveJournal();
    void this.engine?.stop().catch(() => {});
    void this.client?.disconnect();
    void this.shutdown();
  }

  private vaultKey(): string {
    return (this.app as unknown as { appId?: string }).appId ?? this.app.vault.getName();
  }

  private notify(message: string, timeout?: number, onTap?: () => void): void {
    this.record(`shown: ${message}`);
    const notice = new Notice(message, timeout);
    if (onTap) notice.noticeEl.addEventListener("click", onTap);
  }

  private restoreJournal(): void {
    try {
      const saved = JSON.parse(window.localStorage.getItem(`babelsync-journal:${this.vaultKey()}`) ?? "[]");
      if (Array.isArray(saved)) this.journal = saved.filter((line) => typeof line === "string").slice(-MAX_JOURNAL_LINES);
    } catch {
      this.journal = [];
    }
  }

  private saveJournal(): void {
    if (this.journalSave !== null) window.clearTimeout(this.journalSave);
    this.journalSave = null;
    try {
      window.localStorage.setItem(`babelsync-journal:${this.vaultKey()}`, JSON.stringify(this.journal));
    } catch {
      return;
    }
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

  async verify(): Promise<void> {
    if (!this.engine || this.status === "offline") return this.notify("Babel Sync: connect to the server first.");
    this.notify("Babel Sync is checking every file against the server.");
    await this.engine.verify();
    this.record("verified every file against the server");
  }

  private async device(name?: string): Promise<string | null> {
    const token = await this.accessToken();
    if (!token) return null;

    const response = await requestUrl({
      url: `${this.settings.serverUrl}/api/device`,
      method: name === undefined ? "GET" : "PUT",
      contentType: "application/json",
      body: name === undefined ? undefined : JSON.stringify({ name }),
      headers: { authorization: `Bearer ${token}` },
      throw: false,
    });
    return response.status === 200 ? (response.json as { name: string }).name : null;
  }

  private async adoptDeviceName(): Promise<void> {
    const name = await this.device().catch(() => null);
    if (!name || name === this.settings.deviceName) return;

    this.record(`this device is now called ${name}`);
    this.settings.deviceName = name;
    await this.saveSettings();
    await this.restart();
  }

  async renameDevice(name: string): Promise<void> {
    if (!name || name === this.settings.deviceName) return;
    this.settings.deviceName = name;
    await this.saveSettings();
    await this.device(name).catch(() => null);
  }

  private presence(): { name: string; color: string } {
    const { deviceName, clientId } = this.settings;
    const account = this.engine?.account ?? "";
    const name = account && deviceName ? `${account} (${deviceName})` : account || deviceName;
    let mix = 0;
    for (const letter of `${clientId}/${deviceName}`) mix = (mix * 31 + letter.codePointAt(0)!) >>> 0;
    return { name, color: CURSOR_COLORS[mix % CURSOR_COLORS.length] };
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
    if (this.retired) return;
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
      disposable: (path) => path.startsWith(".obsidian/"),
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
    client.socket.onOpen(() => {
      this.record("connection opened");
      void this.fetchUpdate(false);
      void this.adoptDeviceName();
    });
    client.socket.onClose((event: unknown) => {
      const { code, reason } = (event ?? {}) as { code?: number; reason?: string };
      this.record(`connection closed${code ? ` (${code}${reason ? ` ${reason}` : ""})` : ""}`);
    });
    engine.on("log", (line) => this.record(line));
    engine.on("error", (reason) => {
      this.record(`error: ${reason}`);
      if (PASSING.test(reason)) return;
      this.lastError = reason;
      this.notify(`Babel Sync: ${reason}`);
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
    if (!this.settings.storeName) {
      this.settings.storeName = `babelsync-${this.app.vault.getName()}-${this.settings.vaultId}`;
      void this.saveSettings();
    }
    return this.settings.storeName;
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
    this.journal.push(`${new Date().toISOString()} [${this.instance}] ${line}`);
    if (this.journal.length > MAX_JOURNAL_LINES) this.journal.shift();
    this.journalSave ??= window.setTimeout(() => this.saveJournal(), JOURNAL_SAVE_MS);
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
