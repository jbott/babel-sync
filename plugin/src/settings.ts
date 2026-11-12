import { type App, Notice, Platform, PluginSettingTab, Setting } from "obsidian";
import { DisconnectModal } from "./connect.ts";
import { hostOf, normalizeServer } from "./invitation.ts";
import type BabelSyncPlugin from "./main.ts";
import type { Pending, Tokens } from "./oauth.ts";

const MEBIBYTE = 1024 * 1024;

export type Settings = {
  serverUrl: string;
  clientId: string;
  clientServer: string;
  tokens: Tokens | null;
  pendingSignIn: Pending | null;
  vaultId: string;
  vaultName: string;
  deviceName: string;
  syncConfig: boolean;
  maxFileMebibytes: number;
};

export const DEFAULT_SETTINGS: Settings = {
  serverUrl: "",
  clientId: "",
  clientServer: "",
  tokens: null,
  pendingSignIn: null,
  vaultId: "",
  vaultName: "",
  deviceName: Platform.isMobile ? "Phone" : "Desktop",
  syncConfig: true,
  maxFileMebibytes: Platform.isMobile ? 50 : 0,
};

export function maxBlobBytes(settings: Settings): number | undefined {
  return settings.maxFileMebibytes > 0 ? settings.maxFileMebibytes * MEBIBYTE : undefined;
}

export type RemoteVault = { id: string; name: string; role: string; files?: number };

type Reach = "unknown" | "checking" | "open" | "signed-out" | "failed";

function clock(time: number): string {
  return new Date(time).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

export class SettingsTab extends PluginSettingTab {
  private plugin: BabelSyncPlugin;
  private reach: Reach = "unknown";
  private problem = "";
  private signInUrl: string | null = null;
  private summary: Setting | null = null;
  private drawn = "";

  constructor(app: App, plugin: BabelSyncPlugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display(): void {
    this.plugin.onStatus = () => this.statusChanged();
    this.drawn = this.shape();
    this.draw();
    if (this.reach === "unknown") void this.check();
  }

  hide(): void {
    this.plugin.onStatus = null;
    this.summary = null;
    this.reach = "unknown";
    this.signInUrl = null;
    void this.plugin.restart();
  }

  private draw(): void {
    const { containerEl } = this;
    const { settings } = this.plugin;
    containerEl.empty();

    const waiting = !settings.vaultId || this.reach === "signed-out" || this.signInUrl !== null;
    const top = waiting ? this.card(containerEl) : containerEl;

    this.summary = new Setting(top).setHeading();
    this.summarize();

    if (settings.vaultId) this.connected(this.summary);
    else this.connect(top);

    new Setting(containerEl)
      .setName("This device")
      .setDesc("Shown on your cursor and in the names of conflict copies.")
      .addText((text) => {
        text.setValue(settings.deviceName);
        text.inputEl.addEventListener("change", () => void this.plugin.renameDevice(text.getValue().trim()));
      });

    new Setting(containerEl).setName("What syncs").setHeading();

    new Setting(containerEl)
      .setName("Sync Obsidian settings")
      .setDesc("Themes, snippets, hotkeys and plugins, but not window layout.")
      .addToggle((toggle) => toggle.setValue(settings.syncConfig).onChange((value) => this.save({ syncConfig: value })));

    new Setting(containerEl)
      .setName("Largest attachment (MiB)")
      .setDesc("Bigger files stay on the server. 0 means no limit.")
      .addText((text) => {
        text.inputEl.type = "number";
        text.setValue(String(settings.maxFileMebibytes)).onChange((value) => {
          const parsed = Number.parseInt(value, 10);
          void this.save({ maxFileMebibytes: Number.isFinite(parsed) && parsed > 0 ? parsed : 0 });
        });
      });

    new Setting(containerEl).setName("Troubleshooting").setHeading();

    new Setting(containerEl)
      .setName(this.plugin.updated ? "Update ready" : "Reload")
      .setDesc(this.plugin.updated ? "Reload to start using it." : "Restart Babel Sync without restarting Obsidian.")
      .addButton((button) => {
        button.setButtonText(this.plugin.updated ? "Update" : "Reload").onClick(() => this.plugin.reload());
        if (this.plugin.updated) button.setCta();
      });

    new Setting(containerEl)
      .setName("Debug log")
      .setDesc("For bug reports. Includes file names, never passwords.")
      .addButton((button) =>
        button.setButtonText("Copy debug log").onClick(async () => {
          await navigator.clipboard.writeText(this.plugin.debugLog());
          new Notice("Babel Sync: debug log copied.");
        }),
      );

    new Setting(containerEl)
      .setName("Reconnect")
      .setDesc("Reopen the connection to the server.")
      .addButton((button) => button.setButtonText("Reconnect").onClick(() => this.plugin.restart(true)));

    new Setting(containerEl)
      .setName("Verify")
      .setDesc("Recheck every file against the server.")
      .addButton((button) => button.setButtonText("Verify").onClick(() => this.plugin.verify()));

    if (settings.vaultId || settings.tokens) this.leaving(containerEl);

    containerEl.createEl("p", {
      cls: "setting-item-description babelsync-colophon",
      text: `Babel Sync ${this.plugin.manifest.version} · commit ${this.plugin.revision} · build ${this.plugin.build || "unknown"}`,
    });
  }

  private summarize(): void {
    const { name, description } = this.headline();
    this.summary?.setName(name).setDesc(description);
  }

  private connect(containerEl: HTMLElement): void {
    const { serverUrl, tokens } = this.plugin.settings;
    const signInUrl = this.signInUrl;
    const ready = serverUrl !== "" && (tokens !== null || this.reach === "open");
    let address = serverUrl;

    const row = new Setting(containerEl)
      .setName("Server")
      .setDesc("For example notes.example.com")
      .addText((text) => {
        text.setPlaceholder("https://").setValue(serverUrl).onChange((value) => (address = value));
        text.inputEl.addEventListener("keydown", (event) => {
          if (event.key === "Enter") void this.begin(address);
        });
      });

    if (signInUrl) {
      row.addButton((button) =>
        button
          .setButtonText("Open sign-in page")
          .setCta()
          .onClick(() => void window.open(signInUrl)),
      );
    } else {
      row.addButton((button) =>
        button
          .setButtonText(ready ? "Choose vault" : "Sign in")
          .setCta()
          .onClick(() => this.begin(address)),
      );
    }

  }

  private card(containerEl: HTMLElement): HTMLElement {
    const card = containerEl.createDiv();
    Object.assign(card.style, {
      border: "1px solid var(--interactive-accent)",
      borderRadius: "var(--radius-m)",
      background: "var(--background-secondary)",
      padding: "var(--size-4-2) var(--size-4-4)",
      marginBottom: "var(--size-4-6)",
    });
    return card;
  }

  private connected(summary: Setting): void {
    const signInUrl = this.signInUrl;

    if (signInUrl) {
      summary.addButton((button) =>
        button
          .setButtonText("Open sign-in page")
          .setCta()
          .onClick(() => void window.open(signInUrl)),
      );
    } else if (this.reach === "signed-out") {
      summary.addButton((button) =>
        button
          .setButtonText("Sign in")
          .setCta()
          .onClick(() => this.signIn()),
      );
    }

  }

  private leaving(containerEl: HTMLElement): void {
    const { serverUrl, vaultId, vaultName, tokens } = this.plugin.settings;

    new Setting(containerEl).setName("Account").setHeading();

    if (tokens) {
      new Setting(containerEl)
        .setName("Sign out")
        .setDesc(vaultId ? `Syncing with ${vaultName || "the vault"} resumes when you sign back in.` : `Signed in to ${hostOf(serverUrl)}.`)
        .addButton((button) =>
          button.setButtonText("Sign out").onClick(async () => {
            await this.plugin.signOut();
            await this.check();
          }),
        );
    }

    if (!vaultId) return;

    new Setting(containerEl)
      .setName("Disconnect this vault")
      .setDesc("Stop syncing and sign out. Nothing is deleted.")
      .addButton((button) =>
        button
          .setButtonText("Disconnect")
          .setWarning()
          .onClick(() => new DisconnectModal(this.app, this.plugin, () => void this.check()).open()),
      );
  }

  private async begin(value: string): Promise<void> {
    const serverUrl = normalizeServer(value);
    if (!serverUrl) return void new Notice("Enter your server address first.");

    if (serverUrl !== this.plugin.settings.serverUrl) {
      if (this.plugin.settings.tokens) await this.plugin.signOut();
      await this.save({ serverUrl });
    }

    await this.check();
    if (this.reach === "open") await this.plugin.chooseVault();
    if (this.reach === "signed-out") await this.signIn();
  }

  private async signIn(): Promise<void> {
    if (!Platform.isMobile) return this.plugin.signIn();
    this.signInUrl = await this.plugin.prepareSignIn();
    this.draw();
  }

  private headline(): { name: string; description: string } {
    const { serverUrl, vaultId, vaultName, tokens } = this.plugin.settings;
    const ready = "Open the sign-in page and approve this device.";

    if (!vaultId) {
      if (this.reach === "checking") return { name: "Checking the server…", description: hostOf(serverUrl) };
      if (this.reach === "failed") return { name: "Cannot talk to the server", description: this.problem };
      if (this.signInUrl) return { name: "Not connected", description: ready };
      if (serverUrl && (tokens || this.reach === "open")) {
        return {
          name: `Signed in to ${hostOf(serverUrl)}`,
          description: "Now choose a vault to sync with.",
        };
      }
      return {
        name: "Not connected",
        description: "Enter your server and sign in.",
      };
    }

    if (this.reach === "signed-out") {
      return {
        name: `Signed out of ${vaultName || "your vault"} on ${hostOf(serverUrl)}`,
        description: this.signInUrl ? ready : "Sign in to keep syncing. Changes made here are kept.",
      };
    }

    return {
      name: `Syncing with ${vaultName || "your vault"} on ${hostOf(serverUrl)}`,
      description: this.activity(),
    };
  }

  private activity(): string {
    const { status, progress, fileCount, lastSynced, lastError } = this.plugin;
    const files = `${fileCount.toLocaleString()} ${fileCount === 1 ? "file" : "files"}`;

    if (status === "syncing" && progress) {
      const verb = progress.direction === "receiving" ? "Receiving" : "Sending";
      return `${verb} ${(progress.done + 1).toLocaleString()} of ${progress.total.toLocaleString()}…`;
    }
    if (status === "syncing") return "Syncing…";
    if (status === "synced") return `Up to date. ${files}, checked ${clock(lastSynced ?? Date.now())}.`;
    if (status === "error") return `Error: ${lastError || "unknown"}. Try Reconnect.`;

    const since = lastSynced ? ` Last synced ${clock(lastSynced)}.` : "";
    return `Offline. Changes are sent when the server is back.${since}`;
  }

  private statusChanged(): void {
    const shape = this.shape();
    if (shape === this.drawn) return this.summarize();

    this.drawn = shape;
    this.signInUrl = null;
    void this.check();
  }

  private shape(): string {
    const { tokens, vaultId } = this.plugin.settings;
    return `${tokens !== null} ${vaultId}`;
  }

  private async check(): Promise<void> {
    if (!this.plugin.settings.serverUrl) {
      this.reach = "unknown";
      return this.draw();
    }

    this.reach = "checking";
    this.summarize();
    const reply = await this.plugin.remoteVaults();

    if (reply.kind === "vaults") {
      this.reach = "open";
    } else if (reply.kind === "signed-out") {
      this.reach = "signed-out";
    } else {
      this.reach = "failed";
      this.problem = reply.message;
    }

    this.draw();
  }

  private async save(changes: Partial<Settings>): Promise<void> {
    Object.assign(this.plugin.settings, changes);
    await this.plugin.saveSettings();
  }
}
