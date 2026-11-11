import { type App, Modal, Notice, Platform, Setting } from "obsidian";
import { type Invitation, hostOf } from "./invitation.ts";
import type BabelSyncPlugin from "./main.ts";

export class ConnectModal extends Modal {
  private plugin: BabelSyncPlugin;
  private invitation: Invitation;

  constructor(app: App, plugin: BabelSyncPlugin, invitation: Invitation) {
    super(app);
    this.plugin = plugin;
    this.invitation = invitation;
  }

  onOpen(): void {
    this.ask();
  }

  onClose(): void {
    this.contentEl.empty();
  }

  private ask(): void {
    const { server, vaultName } = this.invitation;
    const { settings } = this.plugin;
    const remote = vaultName ? `“${vaultName}”` : "a vault";
    const replacing = settings.serverUrl && settings.vaultId && (settings.serverUrl !== server || settings.vaultId !== this.invitation.vaultId);

    this.setTitle("Connect to Babel Sync");
    this.contentEl.empty();
    this.contentEl.createEl("p", {
      text: `Sync this Obsidian vault (“${this.app.vault.getName()}”) with ${remote} on ${hostOf(server)}?`,
    });
    this.contentEl.createEl("p", {
      cls: "setting-item-description",
      text: "Notes already here are uploaded and merged with what is on the server. Only continue if you trust this server: it will receive every note in this vault.",
    });
    if (replacing) {
      this.contentEl.createEl("p", {
        cls: "mod-warning",
        text: `This replaces the current connection to ${settings.vaultName || "another vault"} on ${hostOf(settings.serverUrl)}.`,
      });
    }

    new Setting(this.contentEl)
      .addButton((button) => button.setButtonText("Cancel").onClick(() => this.close()))
      .addButton((button) =>
        button
          .setButtonText("Connect")
          .setCta()
          .onClick(async () => {
            button.setDisabled(true).setButtonText("Connecting…");
            await this.connect();
          }),
      );
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
    this.contentEl.createEl("p", { text: "One more step: approve this device on the sign-in page. You will come straight back here." });
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
      text: "The connection is saved. You can finish from Settings › Babel Sync.",
    });
    new Setting(this.contentEl).addButton((button) => button.setButtonText("Close").onClick(() => this.close()));
  }
}
