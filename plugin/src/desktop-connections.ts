import { Modal, Notice, Setting, SuggestModal } from "obsidian";
import type BabelSyncPlugin from "./main.ts";
import { connectorWindowPath } from "./connector-window-loader.ts";

import { connection, connectionUserAgent, restoreConnection, type Connection } from "./connection.ts";
import {
  connectionCookies,
  connectionTarget,
  serverConnection,
  type ConnectionTarget,
  type ServerConnection,
  type SessionCookie,
} from "./connection-handoff.ts";

type BrowserSession = {
  cookies: { get(filter: Record<string, never>): Promise<SessionCookie[]> };
};

type Session = {
  open(id: string): Promise<boolean>;
  disconnect(id: string): Promise<boolean>;
  useSession(id: string, action: (session: BrowserSession, agent: string) => Promise<void>): Promise<boolean>;
  dispose(): void;
};

class Picker extends SuggestModal<[string, Connection]> {
  constructor(plugin: BabelSyncPlugin, entries: [string, Connection][], choose: (id: string) => void) {
    super(plugin.app);
    this.getSuggestions = (query) => entries.filter(([, entry]) => entry.name.toLowerCase().includes(query.toLowerCase()));
    this.onChooseSuggestion = ([id]) => choose(id);
    this.setPlaceholder("Choose a connection");
  }
  getSuggestions: (query: string) => [string, Connection][];
  onChooseSuggestion: (item: [string, Connection]) => void;
  renderSuggestion([, entry]: [string, Connection], el: HTMLElement): void {
    el.setText(entry.name);
    el.createEl("small", { text: " · " + new URL(entry.landingUrl).origin });
  }
}

export class DesktopConnections {
  private plugin: BabelSyncPlugin;
  private session?: Session;
  private manager?: Modal;
  private disposed = false;
  private transfers = new Map<string, Promise<ServerConnection | undefined>>();
  private disconnecting = new Set<string>();

  constructor(plugin: BabelSyncPlugin) {
    this.plugin = plugin;
  }

  register(): void {
    const plugin = this.plugin;
    const entries = Object.entries(plugin.settings.connections ?? {});
    plugin.settings.connections = {};
    for (const [id, entry] of entries) {
      if (!/^[a-f0-9-]{36}$/.test(id)) continue;
      try {
        plugin.settings.connections[id] = restoreConnection(entry);
      } catch {
        new Notice("A saved desktop connection has invalid settings.");
      }
    }
    plugin.addCommand({ id: "manage-connections", name: "Manage desktop connections", callback: () => this.manage() });
    plugin.addCommand({ id: "open-connection", name: "Open connection", callback: () => this.pick((id) => void this.runtime()?.open(id)) });
    plugin.addCommand({ id: "disconnect-connection", name: "Disconnect connection", callback: () => this.pick((id) => void this.disconnect(id)) });
    plugin.registerObsidianProtocolHandler("babelsync-login", ({ connection: id }) => {
      const entry = Object.hasOwn(plugin.settings.connections, id) && plugin.settings.connections[id];
      if (!entry) return void new Notice("Unknown connection in this vault.");
      const modal = new Modal(plugin.app);
      modal.setTitle("Open connection?");
      new Setting(modal.contentEl)
        .setName(entry.name)
        .setDesc(new URL(entry.landingUrl).origin)
        .addButton((button) =>
          button
            .setButtonText("Open")
            .setCta()
            .onClick(() => {
              modal.close();
              if (plugin.settings.connections[id] === entry) void this.runtime()?.open(id);
            }),
        );
      modal.open();
    });
  }

  manage(): void {
    if (this.disposed) return;
    this.manager?.close();
    const modal = new Modal(this.plugin.app);
    this.manager = modal;
    modal.setTitle("Desktop connections");
    const draw = () => {
      modal.contentEl.empty();
      for (const [id, entry] of Object.entries(this.plugin.settings.connections)) {
        new Setting(modal.contentEl)
          .setName(entry.name)
          .setDesc(entry.landingUrl)
          .addButton((button) =>
            button.setButtonText("Open").onClick(() => {
              modal.close();
              void this.runtime()?.open(id);
            }),
          )
          .addButton((button) =>
            button.setButtonText("Copy link").onClick(async () => {
              await navigator.clipboard.writeText(
                "obsidian://babelsync-login?" + new URLSearchParams({ vault: this.plugin.app.vault.getName(), connection: id }),
              );
              new Notice("Connection link copied.");
            }),
          )
          .addButton((button) =>
            button.setButtonText("Copy ID").onClick(async () => {
              await navigator.clipboard.writeText(id);
              new Notice("Connection ID copied.");
            }),
          )
          .addButton((button) => button.setButtonText("Edit").onClick(() => edit(id)));
      }
      new Setting(modal.contentEl).addButton((button) =>
        button
          .setButtonText("Add connection")
          .setCta()
          .onClick(() => edit()),
      );
    };
    const edit = (id?: string) => {
      modal.contentEl.empty();
      const old = id ? this.plugin.settings.connections[id] : undefined;
      let name = old?.name ?? "";
      let address = old?.landingUrl ?? "";
      let hosts = old?.allowedHosts.filter((host) => host !== new URL(old.landingUrl).hostname).join(", ") ?? "";
      let agent = old?.userAgent ?? "";
      let selector = old?.checkSelector ?? "";
      new Setting(modal.contentEl).setName("Name").addText((field) =>
        field.setValue(name).onChange((v) => {
          name = v;
        }),
      );
      new Setting(modal.contentEl).setName("Start URL").addText((field) =>
        field.setValue(address).onChange((v) => {
          address = v;
        }),
      );
      new Setting(modal.contentEl)
        .setName("Additional sign-in hosts")
        .setDesc("Exact host names, separated by commas.")
        .addText((field) =>
          field.setValue(hosts).onChange((v) => {
            hosts = v;
          }),
        );
      new Setting(modal.contentEl)
        .setName("User agent")
        .setDesc("Leave blank to use the default Chrome user agent. Changes apply when you reopen the connection.")
        .addText((field) =>
          field.setValue(agent).onChange((v) => {
            agent = v;
          }),
        );
      new Setting(modal.contentEl)
        .setName("Signed-in CSS selector")
        .setDesc("An element on the start page that appears only when signed in. Required for server sync.")
        .addText((field) =>
          field.setValue(selector).onChange((v) => {
            selector = v;
          }),
        );
      const actions = new Setting(modal.contentEl);
      let busy = false;
      const save = async (remove: boolean) => {
        if (busy || this.disposed) return;
        busy = true;
        try {
          const next = remove ? undefined : connection(name, address, hosts.split(","), agent, selector);
          const changedScope = old && (next?.landingUrl !== old.landingUrl || JSON.stringify(next?.allowedHosts) !== JSON.stringify(old.allowedHosts));
          if (id && changedScope && !(await this.disconnect(id))) return;
          const key = id ?? crypto.randomUUID();
          const entries = this.plugin.settings.connections;
          if (next) entries[key] = next;
          else delete entries[key];
          try {
            await this.plugin.saveSettings();
          } catch (error) {
            if (old) entries[key] = old;
            else delete entries[key];
            throw error;
          }
          draw();
        } catch (error) {
          new Notice(error instanceof Error ? error.message : "Could not save the connection.");
        } finally {
          busy = false;
        }
      };
      actions.addButton((button) =>
        button
          .setButtonText("Save")
          .setCta()
          .onClick(() => save(false)),
      );
      if (old) actions.addButton((button) => button.setButtonText("Disconnect and remove").onClick(() => save(true)));
      actions.addButton((button) => button.setButtonText("Back").onClick(draw));
    };
    draw();
    modal.open();
  }

  private async disconnect(id: string): Promise<boolean> {
    const entry = this.plugin.settings.connections[id];
    if (entry && new URL(entry.landingUrl).protocol === "https:" && this.plugin.settings.serverUrl && this.plugin.settings.vaultId) {
      try {
        const target = connectionTarget(this.plugin.settings);
        await this.disconnectServer(target, id);
      } catch (error) {
        this.explain(error);
        return false;
      }
    }
    return (await this.runtime()?.disconnect(id)) === true;
  }

  private renderActions(id: string, content: HTMLElement): void {
    const entry = this.plugin.settings.connections[id];
    if (!entry || new URL(entry.landingUrl).protocol !== "https:") return;
    const action = new Setting(content)
      .setName("Server sync")
      .setDesc("Sign in, then connect this session to your Babel server.")
      .addButton((button) => button.setButtonText("Connect server sync").onClick(() => this.confirmHandoff(id)))
      .addButton((button) =>
        button.setButtonText("Disconnect server sync").onClick(async () => {
          button.setDisabled(true);
          try {
            await this.disconnectServer(connectionTarget(this.plugin.settings), id);
            action.setDesc("Server sync disconnected. Sign in and connect again to resume.");
          } catch (error) {
            this.explain(error);
          } finally {
            button.setDisabled(false);
          }
        }),
      );
    void this.status(id, action);
  }

  private async status(id: string, setting: Setting): Promise<void> {
    try {
      const status = await this.request(connectionTarget(this.plugin.settings), id, "GET");
      if (this.disposed) return;
      setting.setDesc(
        status.status === "connected"
          ? "The server has this session. Approved sources can sync while Obsidian is closed."
          : "Sign in, then connect this session to your Babel server.",
      );
    } catch (error) {
      setting.setDesc(error instanceof Error ? error.message : "Could not check server sync.");
    }
  }

  private confirmHandoff(id: string): void {
    const entry = this.plugin.settings.connections[id];
    if (this.disposed || !entry) return;
    let target: ConnectionTarget;
    try {
      target = connectionTarget(this.plugin.settings);
      if (!entry.checkSelector) throw new Error("Set a signed-in CSS selector in this connection’s settings before connecting server sync.");
      if (new URL(entry.landingUrl).protocol !== "https:") throw new Error("Server sync requires an HTTPS start URL.");
    } catch (error) {
      return this.explain(error);
    }
    const modal = new Modal(this.plugin.app);
    modal.setTitle("Connect server sync?");
    modal.contentEl.createEl("p", {
      text: `Send the session for ${entry.name} to ${new URL(target.serverUrl).origin} for vault “${this.plugin.settings.vaultName || this.plugin.app.vault.getName()}”?`,
    });
    modal.contentEl.createEl("p", {
      text: `The server will store the session encrypted and let approved vault sources make signed-in requests to ${entry.allowedHosts.join(", ")} while Obsidian is closed. You can disconnect server sync here.`,
    });
    new Setting(modal.contentEl)
      .addButton((button) => button.setButtonText("Cancel").onClick(() => modal.close()))
      .addButton((button) =>
        button
          .setButtonText("Connect server sync")
          .setCta()
          .onClick(async () => {
            button.setDisabled(true).setButtonText("Connecting…");
            try {
              const connected = await this.handoff(id, entry, target);
              if (connected) {
                modal.close();
                new Notice("Session connected. Approved vault sources can use this connection ID.");
              }
            } catch (error) {
              this.explain(error);
            } finally {
              button.setDisabled(false).setButtonText("Connect server sync");
            }
          }),
      );
    modal.open();
  }

  private async handoff(id: string, entry: Connection, target: ConnectionTarget): Promise<ServerConnection | undefined> {
    if (this.transfers.has(id) || this.disconnecting.has(id)) throw new Error("This connection is being updated. Wait for it to finish.");
    const transfer = this.transfer(id, entry, target);
    this.transfers.set(id, transfer);
    try {
      return await transfer;
    } finally {
      this.transfers.delete(id);
    }
  }

  private async disconnectServer(target: ConnectionTarget, id: string): Promise<void> {
    if (this.disconnecting.has(id)) throw new Error("This connection is already disconnecting.");
    this.disconnecting.add(id);
    try {
      await this.transfers.get(id)?.catch(() => undefined);
      await this.request(target, id, "DELETE");
    } finally {
      this.disconnecting.delete(id);
    }
  }

  private async transfer(id: string, entry: Connection, target: ConnectionTarget): Promise<ServerConnection | undefined> {
    const runtime = this.runtime();
    if (!runtime) return;
    let result: ServerConnection | undefined;
    let failure: unknown;
    await runtime.useSession(id, async (session, agent) => {
      try {
        if (this.disposed || this.plugin.settings.connections[id] !== entry) throw new Error("The connection changed. Open it again.");
        const cookies = connectionCookies(await session.cookies.get({}), entry.allowedHosts);
        if (!cookies.length) throw new Error("Sign in in this connection first.");
        result = await this.request(
          target,
          id,
          "POST",
          {
            name: entry.name,
            landing_url: entry.landingUrl,
            hosts: entry.allowedHosts,
            user_agent: agent,
            cookies,
            check_selector: entry.checkSelector,
          },
          entry,
        );
      } catch (error) {
        failure = error;
      }
    });
    if (failure) throw failure;
    return result;
  }

  private async request(
    target: ConnectionTarget,
    id: string,
    method: "GET" | "POST" | "DELETE",
    body?: unknown,
    entry?: Connection,
  ): Promise<ServerConnection> {
    const token = await this.plugin.accessToken();
    if (!token) throw new Error("Sign in to Babel Sync before connecting server sync.");
    const current = connectionTarget(this.plugin.settings);
    if (this.disposed || current.serverUrl !== target.serverUrl || current.vaultId !== target.vaultId) {
      throw new Error("The Babel server or vault changed. Open the connection again.");
    }
    if (entry && this.plugin.settings.connections[id] !== entry) throw new Error("The connection changed. Open it again.");
    return serverConnection(target, id, token, method, body);
  }

  private explain(error: unknown): void {
    new Notice(error instanceof Error ? error.message : "Could not update server sync. Try again.");
  }

  private pick(choose: (id: string) => void): void {
    const entries = Object.entries(this.plugin.settings.connections);
    if (entries.length === 0) this.manage();
    else new Picker(this.plugin, entries, choose).open();
  }

  private runtime(): Session | undefined {
    if (this.disposed) return;
    if (!this.session) {
      try {
        const remote = require("@electron/remote");
        const { join } = require("path");
        const basePath = (this.plugin.app.vault.adapter as { getBasePath?: () => string }).getBasePath?.();
        if (!basePath || !this.plugin.manifest.dir) throw new Error("Plugin path unavailable");
        const windows = remote.require(connectorWindowPath(join(basePath, this.plugin.manifest.dir)));
        const ConnectorSession = require("./connector-session.cjs");
        const connectors = this.plugin.settings.connections;
        this.session = new ConnectorSession({
          app: this.plugin.app,
          Modal,
          session: remote.session,
          createWindow: (entry: Connection, partition: string, agent: string) => windows.create(entry, partition, agent, remote.getCurrentWindow().id),
          connectors,
          getUserAgent: (id: string) => connectionUserAgent(connectors[id]?.userAgent),
          renderActions: (id: string, content: HTMLElement) => this.renderActions(id, content),
          notice: (message: string) => new Notice(message),
        });
      } catch {
        new Notice("This desktop installation cannot open an isolated connection.");
      }
    }
    return this.session;
  }

  dispose(): void {
    this.disposed = true;
    this.manager?.close();
    this.session?.dispose();
  }
}
