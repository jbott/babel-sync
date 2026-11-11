import { type App, type ButtonComponent, Platform, PluginSettingTab, Setting, requestUrl } from "obsidian";
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
  deviceName: Platform.isMobile ? "Phone" : "Desktop",
  userName: "",
  userColor: "#7c3aed",
  syncConfig: true,
  maxFileMebibytes: Platform.isMobile ? 50 : 0,
};

export function maxBlobBytes(settings: Settings): number | undefined {
  return settings.maxFileMebibytes > 0 ? settings.maxFileMebibytes * MEBIBYTE : undefined;
}

type RemoteVault = { id: string; name: string; role: string };

export class SettingsTab extends PluginSettingTab {
  private plugin: BabelSyncPlugin;
  private vaults: RemoteVault[] = [];
  private notice = "";
  private signInUrl: string | null = null;

  constructor(app: App, plugin: BabelSyncPlugin) {
    super(app, plugin);
    this.plugin = plugin;
  }

  display(): void {
    const { containerEl } = this;
    const { settings } = this.plugin;
    containerEl.empty();

    new Setting(containerEl)
      .setName("Server")
      .setDesc("Address of your BabelSync server, for example https://notes.example.com")
      .addText((text) =>
        text
          .setPlaceholder("https://")
          .setValue(settings.serverUrl)
          .onChange((value) => this.save({ serverUrl: value.trim().replace(/\/+$/, "") })),
      );

    new Setting(containerEl)
      .setName("Account")
      .setDesc(this.accountDescription())
      .addButton((button) => this.accountButton(button));

    new Setting(containerEl)
      .setName("Vault")
      .setDesc(this.notice || "The server vault this Obsidian vault syncs with.")
      .addDropdown((dropdown) => {
        dropdown.addOption("", "Not connected");
        for (const vault of this.options()) dropdown.addOption(vault.id, `${vault.name} (${vault.role})`);
        dropdown.setValue(settings.vaultId).onChange((value) => this.save({ vaultId: value }, true));
      })
      .addButton((button) => button.setButtonText("Load vaults").onClick(() => this.loadVaults()));

    new Setting(containerEl)
      .setName("Device name")
      .setDesc("Names the copy kept when two devices change the same attachment.")
      .addText((text) =>
        text.setValue(settings.deviceName).onChange((value) => this.save({ deviceName: value.trim() })),
      );

    new Setting(containerEl)
      .setName("Your name")
      .setDesc("Shown next to your cursor for other people editing the same note.")
      .addText((text) => text.setValue(settings.userName).onChange((value) => this.save({ userName: value.trim() })))
      .addColorPicker((picker) =>
        picker.setValue(settings.userColor).onChange((value) => this.save({ userColor: value })),
      );

    new Setting(containerEl)
      .setName("Sync Obsidian settings")
      .setDesc("Themes, snippets, hotkeys and plugins. Window layout stays on each device.")
      .addToggle((toggle) =>
        toggle.setValue(settings.syncConfig).onChange((value) => this.save({ syncConfig: value }, true)),
      );

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

    new Setting(containerEl)
      .setName("Start over")
      .setDesc("Forget what this device has synced and compare everything with the server again.")
      .addButton((button) => button.setButtonText("Resync").onClick(() => this.plugin.resync()));
  }

  hide(): void {
    void this.plugin.restart();
  }

  private accountDescription(): string {
    if (this.plugin.settings.tokens) return "This device is signed in.";
    if (this.signInUrl) return "Sign-in is ready. Open the page, approve this device, and come back.";
    return "Not signed in. A server that runs without sign-in works as it is.";
  }

  private accountButton(button: ButtonComponent): void {
    const signInUrl = this.signInUrl;

    if (this.plugin.settings.tokens) {
      this.signInUrl = null;
      button.setButtonText("Sign out").onClick(async () => {
        await this.plugin.signOut();
        this.display();
      });
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
          this.display();
        });
    }
  }

  private options(): RemoteVault[] {
    const { vaultId } = this.plugin.settings;
    if (!vaultId || this.vaults.some((vault) => vault.id === vaultId)) return this.vaults;
    return [...this.vaults, { id: vaultId, name: vaultId.slice(0, 8), role: "current" }];
  }

  private async save(changes: Partial<Settings>, redraw = false): Promise<void> {
    Object.assign(this.plugin.settings, changes);
    await this.plugin.saveSettings();
    if (redraw) this.display();
  }

  private async loadVaults(): Promise<void> {
    const { serverUrl } = this.plugin.settings;

    try {
      const token = await this.plugin.accessToken();
      const response = await requestUrl({
        url: `${serverUrl}/api/vaults`,
        headers: token ? { authorization: `Bearer ${token}` } : {},
        throw: false,
      });

      if (response.status === 200) {
        this.vaults = response.json.vaults;
        this.notice = this.vaults.length === 0 ? "No vaults yet. Create one in the web app." : "";
      } else {
        this.notice = response.status === 401 ? "Sign in first." : `Server answered ${response.status}.`;
      }
    } catch {
      this.notice = "Could not reach the server.";
    }

    this.display();
  }
}
