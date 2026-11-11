import { type App, type ButtonComponent, Platform, PluginSettingTab, Setting } from "obsidian";
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
  userName: string;
  userColor: string;
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
  userName: "",
  userColor: "#7c3aed",
  syncConfig: true,
  maxFileMebibytes: Platform.isMobile ? 50 : 0,
};

export function maxBlobBytes(settings: Settings): number | undefined {
  return settings.maxFileMebibytes > 0 ? settings.maxFileMebibytes * MEBIBYTE : undefined;
}

export type RemoteVault = { id: string; name: string; role: string };

type Reach = "unknown" | "checking" | "open" | "signed-out" | "failed";

function clock(time: number): string {
  return new Date(time).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

export class SettingsTab extends PluginSettingTab {
  private plugin: BabelSyncPlugin;
  private vaults: RemoteVault[] = [];
  private reach: Reach = "unknown";
  private problem = "";
  private signInUrl: string | null = null;
  private summary: Setting | null = null;
  private signedIn = false;

  constructor(app: App, plugin: BabelSyncPlugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display(): void {
    this.plugin.onStatus = () => this.statusChanged();
    this.signedIn = this.plugin.settings.tokens !== null;
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

    this.summary = new Setting(containerEl).setHeading();
    this.summarize();

    new Setting(containerEl)
      .setName("Server")
      .setDesc("Address of your Babel Sync server, for example notes.example.com")
      .addText((text) => {
        text.setPlaceholder("https://").setValue(settings.serverUrl);
        text.inputEl.addEventListener("change", () => void this.changeServer(text.getValue()));
      });

    if (settings.serverUrl) {
      new Setting(containerEl)
        .setName("Account")
        .setDesc(this.accountDescription())
        .addButton((button) => this.accountButton(button));
    }

    if (this.reach === "open") {
      new Setting(containerEl)
        .setName("Vault")
        .setDesc(
          this.vaults.length === 0
            ? "There are no vaults on the server yet. Create one in the web app, then come back."
            : "The server vault this Obsidian vault syncs with. Notes already here are merged into it.",
        )
        .addDropdown((dropdown) => {
          dropdown.addOption("", "Choose a vault");
          for (const vault of this.options()) dropdown.addOption(vault.id, vault.name);
          dropdown.setValue(settings.vaultId).onChange((value) => this.chooseVault(value));
        });
    }

    new Setting(containerEl).setName("You").setHeading();

    new Setting(containerEl)
      .setName("Your name")
      .setDesc("Shown next to your cursor for other people editing the same note.")
      .addText((text) => text.setValue(settings.userName).onChange((value) => this.save({ userName: value.trim() })))
      .addColorPicker((picker) =>
        picker.setValue(settings.userColor).onChange((value) => this.save({ userColor: value })),
      );

    new Setting(containerEl)
      .setName("Device name")
      .setDesc("How this device appears on the server, and the name given to the copy kept when two devices change the same attachment.")
      .addText((text) =>
        text.setValue(settings.deviceName).onChange((value) => this.save({ deviceName: value.trim() })),
      );

    new Setting(containerEl).setName("What syncs").setHeading();

    new Setting(containerEl)
      .setName("Sync Obsidian settings")
      .setDesc("Themes, snippets, hotkeys and plugins. Window layout stays on each device.")
      .addToggle((toggle) => toggle.setValue(settings.syncConfig).onChange((value) => this.save({ syncConfig: value })));

    new Setting(containerEl)
      .setName("Largest attachment (MiB)")
      .setDesc("Bigger files are left on the server and not downloaded here. 0 means no limit.")
      .addText((text) => {
        text.inputEl.type = "number";
        text.setValue(String(settings.maxFileMebibytes)).onChange((value) => {
          const parsed = Number.parseInt(value, 10);
          void this.save({ maxFileMebibytes: Number.isFinite(parsed) && parsed > 0 ? parsed : 0 });
        });
      });

    new Setting(containerEl).setName("Troubleshooting").setHeading();

    new Setting(containerEl)
      .setName(this.plugin.updated ? "Update ready" : "Version")
      .setDesc(
        this.plugin.updated
          ? `A newer plugin has synced to this device. This one is build ${this.plugin.build}; reload to switch.`
          : `Build ${this.plugin.build || "unknown"}. Updates arrive through sync; reload after one to use it.`,
      )
      .addButton((button) => {
        button.setButtonText("Reload plugin").onClick(() => this.plugin.reload());
        if (this.plugin.updated) button.setCta();
      });

    new Setting(containerEl)
      .setName("Reconnect")
      .setDesc("Drop the connection to the server and open it again.")
      .addButton((button) => button.setButtonText("Reconnect").onClick(() => this.plugin.restart(true)));

    new Setting(containerEl)
      .setName("Compare everything again")
      .setDesc("Forget what this device has synced and compare every file with the server. Nothing is deleted.")
      .addButton((button) => button.setButtonText("Compare").onClick(() => this.plugin.resync()));
  }

  private summarize(): void {
    const { name, description } = this.headline();
    this.summary?.setName(name).setDesc(description);
  }

  private headline(): { name: string; description: string } {
    const { serverUrl, vaultId, vaultName, tokens } = this.plugin.settings;

    if (!serverUrl) {
      return {
        name: "Step 1 of 3: enter your server",
        description: "Type the address below. Or open the vault in the web app and choose Connect Obsidian to set all of this up with one tap.",
      };
    }
    if (this.reach === "checking") return { name: "Checking the server…", description: hostOf(serverUrl) };
    if (this.reach === "failed") return { name: "Cannot talk to the server", description: this.problem };
    if (this.reach === "signed-out" || (this.reach === "unknown" && !tokens && !vaultId)) {
      return {
        name: "Step 2 of 3: sign in",
        description: this.signInUrl
          ? "Sign-in is ready. Open the page, approve this device, and you will come straight back."
          : `Sign in to ${hostOf(serverUrl)} so this device can sync.`,
      };
    }
    if (!vaultId) return { name: "Step 3 of 3: choose a vault", description: "Pick the server vault to sync with below." };

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
    if (status === "synced") return `Everything is up to date. ${files}, checked at ${clock(lastSynced ?? Date.now())}.`;
    if (status === "error") return `Stopped on an error: ${lastError || "unknown"}. Try Reconnect below.`;

    const since = lastSynced ? ` Last in sync at ${clock(lastSynced)}.` : "";
    return `Offline. Changes are kept and sent when the server is reachable again.${since}`;
  }

  private statusChanged(): void {
    const signedIn = this.plugin.settings.tokens !== null;
    if (signedIn === this.signedIn) return this.summarize();

    this.signedIn = signedIn;
    this.signInUrl = null;
    void this.check();
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
      this.vaults = reply.vaults;
      this.reach = "open";
      if (!this.plugin.settings.vaultId && reply.vaults.length === 1) return this.chooseVault(reply.vaults[0]!.id);
    } else if (reply.kind === "signed-out") {
      this.reach = "signed-out";
    } else {
      this.reach = "failed";
      this.problem = reply.message;
    }

    this.draw();
  }

  private async changeServer(value: string): Promise<void> {
    const serverUrl = normalizeServer(value) ?? "";
    if (serverUrl === this.plugin.settings.serverUrl) return this.draw();

    this.signedIn = false;
    if (this.plugin.settings.tokens) await this.plugin.signOut();
    await this.save({ serverUrl, vaultId: "", vaultName: "" });
    this.signInUrl = null;
    this.vaults = [];
    await this.check();
  }

  private async chooseVault(vaultId: string): Promise<void> {
    const vaultName = this.vaults.find((vault) => vault.id === vaultId)?.name ?? "";
    await this.save({ vaultId, vaultName });
    await this.plugin.restart();
    this.draw();
  }

  private accountDescription(): string {
    if (this.plugin.settings.tokens) return "This device is signed in.";
    if (this.reach === "open") return "This server does not ask for sign-in.";
    if (this.signInUrl) return "Open the page, approve this device, and come back.";
    return "Not signed in.";
  }

  private accountButton(button: ButtonComponent): void {
    const signInUrl = this.signInUrl;

    if (this.plugin.settings.tokens) {
      button.setButtonText("Sign out").onClick(() => this.plugin.signOut());
    } else if (this.reach === "open") {
      button.setButtonText("Not needed").setDisabled(true);
    } else if (signInUrl) {
      button
        .setButtonText("Open sign-in page")
        .setCta()
        .onClick(() => void window.open(signInUrl));
    } else {
      button
        .setButtonText("Sign in")
        .setCta()
        .onClick(async () => {
          if (!Platform.isMobile) return this.plugin.signIn();
          this.signInUrl = await this.plugin.prepareSignIn();
          this.draw();
        });
    }
  }

  private options(): RemoteVault[] {
    const { vaultId, vaultName } = this.plugin.settings;
    if (!vaultId || this.vaults.some((vault) => vault.id === vaultId)) return this.vaults;
    return [...this.vaults, { id: vaultId, name: vaultName || "Current vault", role: "current" }];
  }

  private async save(changes: Partial<Settings>): Promise<void> {
    Object.assign(this.plugin.settings, changes);
    await this.plugin.saveSettings();
  }
}
