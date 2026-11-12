import { type App, Modal, Notice, Platform, Setting } from "obsidian";
import { type Invitation, hostOf } from "./invitation.ts";
import type BabelSyncPlugin from "./main.ts";
import type { RemoteVault } from "./settings.ts";

export class ConnectModal extends Modal {
  private plugin: BabelSyncPlugin;
  private invitation: Invitation;
  private done: () => void;

  constructor(app: App, plugin: BabelSyncPlugin, invitation: Invitation, done: () => void = () => {}) {
    super(app);
    this.plugin = plugin;
    this.invitation = invitation;
    this.done = done;
  }

  onOpen(): void {
    this.ask();
  }

  onClose(): void {
    this.contentEl.empty();
    this.done();
  }

  private ask(): void {
    const { server, vaultId, vaultName, files: there } = this.invitation;
    const { settings } = this.plugin;
    const remote = vaultName ? `“${vaultName}”` : "a vault";
    const local = `“${this.app.vault.getName()}”`;
    const here = this.app.vault.getFiles().length;
    const bound = settings.serverUrl !== "" && settings.vaultId !== "";
    const switching = bound && (settings.serverUrl !== server || settings.vaultId !== vaultId);
    const current = `${settings.vaultName ? `“${settings.vaultName}”` : "another vault"} on ${hostOf(settings.serverUrl)}`;

    this.setTitle(switching ? "Mix two vaults?" : "Connect to Babel Sync");
    this.contentEl.empty();

    if (switching) {
      this.contentEl.createEl("p", {
        cls: "mod-warning",
        text: `This vault already syncs with ${current}. Pointing it at another one mixes the two.`,
      });
      this.contentEl.createEl("p", {
        text: `The ${count(here)} here are copied into ${remote} on ${hostOf(server)}, and everything there is copied here. This cannot be undone.`,
      });
      this.contentEl.createEl("p", {
        cls: "setting-item-description",
        text: `To get ${remote} on this device, connect a new, empty vault instead.`,
      });
    } else {
      this.contentEl.createEl("p", { text: `Sync this Obsidian vault (${local}) with ${remote} on ${hostOf(server)}?` });
      this.contentEl.createEl("p", { cls: "setting-item-description", text: this.consequence(here, there, remote) });
      this.contentEl.createEl("p", {
        cls: "setting-item-description",
        text: "The server receives every note in this vault.",
      });
    }

    const merging = switching || (here > 0 && there !== 0);
    new Setting(this.contentEl)
      .addButton((button) => {
        button.setButtonText("Cancel").onClick(() => this.close());
        if (switching) button.setCta();
      })
      .addButton((button) => {
        button.setButtonText(switching ? "Mix them anyway" : merging ? "Merge and connect" : "Connect").onClick(async () => {
          button.setDisabled(true).setButtonText("Connecting…");
          await this.connect();
        });
        if (switching) button.setWarning();
        else button.setCta();
      });
  }

  private consequence(here: number, there: number | undefined, remote: string): string {
    if (here === 0) return `This vault is empty and will be filled from ${remote}.`;
    if (there === 0) return `${remote} is empty. The ${count(here)} here will be uploaded.`;

    const theirs = there === undefined ? `whatever is in ${remote}` : `the ${count(there)} in ${remote}`;
    return `The ${count(here)} here and ${theirs} will be merged. Nothing is deleted. Files that differ are both kept.`;
  }

  private async connect(): Promise<void> {
    await this.plugin.adopt(this.invitation);
    const reply = await this.plugin.remoteVaults();

    if (reply.kind === "vaults") {
      new Notice("Babel Sync is connected.");
      return this.close();
    }
    if (reply.kind !== "signed-out") return this.explain(reply.message);

    const url = await this.plugin.prepareSignIn();
    if (!url) return this.explain("Sign-in could not be started. Try again from Settings › Babel Sync.");
    if (!Platform.isMobile) {
      window.open(url);
      return this.close();
    }

    this.contentEl.empty();
    this.contentEl.createEl("p", { text: "Approve this device on the sign-in page." });
    new Setting(this.contentEl).addButton((button) =>
      button
        .setButtonText("Open sign-in page")
        .setCta()
        .onClick(() => {
          window.open(url);
          this.close();
        }),
    );
  }

  private explain(message: string): void {
    this.contentEl.empty();
    this.contentEl.createEl("p", { text: message });
    this.contentEl.createEl("p", {
      cls: "setting-item-description",
      text: "You can finish from Settings › Babel Sync.",
    });
    new Setting(this.contentEl).addButton((button) => button.setButtonText("Close").onClick(() => this.close()));
  }
}

export class VaultPickerModal extends Modal {
  private vaults: RemoteVault[];
  private chosen: (vault: RemoteVault) => void;

  constructor(app: App, vaults: RemoteVault[], chosen: (vault: RemoteVault) => void) {
    super(app);
    this.vaults = vaults;
    this.chosen = chosen;
  }

  onOpen(): void {
    this.setTitle("Which vault?");
    this.contentEl.createEl("p", {
      cls: "setting-item-description",
      text: "Choose a vault to sync with. Nothing is sent until you confirm.",
    });

    for (const vault of this.vaults) {
      new Setting(this.contentEl)
        .setName(vault.name)
        .setDesc(vault.files === undefined ? "" : count(vault.files))
        .addButton((button) =>
          button.setButtonText("Choose").onClick(() => {
            this.close();
            this.chosen(vault);
          }),
        );
    }
  }

  onClose(): void {
    this.contentEl.empty();
  }
}

export class DisconnectModal extends Modal {
  private plugin: BabelSyncPlugin;
  private done: () => void;

  constructor(app: App, plugin: BabelSyncPlugin, done: () => void) {
    super(app);
    this.plugin = plugin;
    this.done = done;
  }

  onOpen(): void {
    const { vaultName, serverUrl } = this.plugin.settings;
    this.setTitle("Disconnect vault?");
    this.contentEl.createEl("p", {
      text: `Stop syncing with ${vaultName ? `“${vaultName}”` : "the vault"} on ${hostOf(serverUrl)}. Nothing is deleted.`,
    });
    this.contentEl.createEl("p", {
      cls: "setting-item-description",
      text: "Connecting again later compares every file from scratch.",
    });

    new Setting(this.contentEl)
      .addButton((button) => button.setButtonText("Cancel").onClick(() => this.close()))
      .addButton((button) =>
        button
          .setButtonText("Disconnect")
          .setWarning()
          .onClick(async () => {
            await this.plugin.disconnect();
            await this.plugin.signOut();
            this.close();
          }),
      );
  }

  onClose(): void {
    this.contentEl.empty();
    this.done();
  }
}

function count(files: number): string {
  return `${files.toLocaleString()} ${files === 1 ? "file" : "files"}`;
}
