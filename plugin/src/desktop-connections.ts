import { Modal, Notice, Setting, SuggestModal } from "obsidian";
import type BabelSyncPlugin from "./main.ts";
import { ConnectionCheck } from "./connection-check.ts";
import { connectorWindowPath } from "./connector-window-loader.ts";

import { connection, connectionUserAgent, restoreConnection, type Connection } from "./connection.ts";
import {
  ConnectionError,
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
  open(id: string, flowId?: string): Promise<boolean>;
  close(id: string): Promise<boolean>;
  setStatus(id: string, message: string, title: string): void;
  disconnect(id: string): Promise<boolean>;
  useSession(id: string, action: (session: BrowserSession, agent: string) => Promise<void>): Promise<boolean>;
  dispose(): void;
};

type GuidedConnection = {
  id: string;
  entry: Connection;
  target: ConnectionTarget;
  destination: string;
  check: ConnectionCheck;
  opening: boolean;
  setting?: Setting;
};

class Picker extends SuggestModal<[string, Connection]> {
  constructor(plugin: BabelSyncPlugin, entries: [string, Connection][], choose: (id: string) => void, description: (entry: Connection) => string) {
    super(plugin.app);
    this.getSuggestions = (query) => entries.filter(([, entry]) => entry.name.toLowerCase().includes(query.toLowerCase()));
    this.onChooseSuggestion = ([id]) => choose(id);
    this.setPlaceholder("Choose a connection");
    this.description = description;
  }
  private description: (entry: Connection) => string;
  getSuggestions: (query: string) => [string, Connection][];
  onChooseSuggestion: (item: [string, Connection]) => void;
  renderSuggestion([, entry]: [string, Connection], el: HTMLElement): void {
    el.setText(entry.name);
    el.createEl("small", { text: " · " + this.description(entry) });
  }
}

export class DesktopConnections {
  private plugin: BabelSyncPlugin;
  private session?: Session;
  private manager?: Modal;
  private disposed = false;
  private transfers = new Map<string, Promise<ServerConnection | undefined>>();
  private disconnecting = new Set<string>();
  private flows = new Map<string, GuidedConnection>();

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
    plugin.addCommand({
      id: "open-connection",
      name: "Sign in and connect",
      callback: () => this.pick((id, entry, target) => void this.start(id, entry, target)),
    });
    plugin.addCommand({ id: "disconnect-connection", name: "Disconnect connection", callback: () => this.pick((id) => void this.disconnect(id)) });
    plugin.registerObsidianProtocolHandler("babelsync-login", ({ connection: id }) => {
      const entry = Object.hasOwn(plugin.settings.connections, id) && plugin.settings.connections[id];
      if (!entry) return void new Notice("Unknown connection in this vault.");
      const modal = new Modal(plugin.app);
      const target = this.syncTarget(entry);
      modal.setTitle(target ? "Sign in and connect?" : "Open connection?");
      new Setting(modal.contentEl)
        .setName(entry.name)
        .setDesc(this.description(entry, target))
        .addButton((button) =>
          button
            .setButtonText(target ? "Sign in and connect" : "Open sign-in window")
            .setCta()
            .onClick(() => {
              modal.close();
              void this.start(id, entry, target ?? null);
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
        const target = this.syncTarget(entry);
        new Setting(modal.contentEl)
          .setName(entry.name)
          .setDesc(this.description(entry, target))
          .addButton((button) =>
            button.setButtonText(target ? "Sign in and connect" : "Open sign-in window").onClick(() => {
              modal.close();
              void this.start(id, entry, target ?? null);
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
          if (id) this.stopFlow(id);
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
    this.stopFlow(id);
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

  private syncTarget(entry: Connection): ConnectionTarget | undefined {
    if (!entry.checkSelector || new URL(entry.landingUrl).protocol !== "https:") return;
    return this.serverTarget();
  }

  private serverTarget(): ConnectionTarget | undefined {
    try {
      return connectionTarget(this.plugin.settings);
    } catch {
      return;
    }
  }

  private destination(target: ConnectionTarget): string {
    const name = this.plugin.settings.vaultName || this.plugin.app.vault.getName();
    return `vault “${name}” on ${target.serverUrl}`;
  }

  private description(entry: Connection, target: ConnectionTarget | null | undefined = this.syncTarget(entry)): string {
    if (target) return `${new URL(entry.landingUrl).origin} · Sign in to automatically connect this session to ${this.destination(target)}.`;
    return `${new URL(entry.landingUrl).origin} · Sign-in only. Configure a Babel server, vault and signed-in selector to enable automatic server sync.`;
  }

  private currentFlow(id: string, flow: GuidedConnection): boolean {
    if (this.disposed || this.flows.get(id) !== flow || this.disconnecting.has(id) || this.plugin.settings.connections[id] !== flow.entry) return false;
    try {
      const current = connectionTarget(this.plugin.settings);
      return current.serverUrl === flow.target.serverUrl && current.vaultId === flow.target.vaultId;
    } catch {
      return false;
    }
  }

  private stopFlow(id: string, flowId?: string, paused = true): void {
    const flow = this.flows.get(id);
    if (!flow || (flowId !== undefined && flow.id !== flowId)) return;
    flow.check.stop();
    if (paused) flow.setting?.setDesc(`Automatic connection paused. Show the sign-in window to connect to ${flow.destination}.`);
    this.flows.delete(id);
  }

  private progress(id: string, flow: GuidedConnection, message: string, title: string): void {
    if (!this.currentFlow(id, flow)) return;
    flow.setting?.setDesc(`${message} Destination: ${flow.destination}.`);
    this.session?.setStatus(id, message, title);
  }

  private async start(
    id: string,
    entry = this.plugin.settings.connections[id],
    target: ConnectionTarget | null | undefined = entry && this.syncTarget(entry),
  ): Promise<void> {
    if (this.disposed || !entry || this.plugin.settings.connections[id] !== entry || this.disconnecting.has(id)) return;
    const runtime = this.runtime();
    if (!runtime) return;
    if (!target) {
      this.stopFlow(id);
      await runtime.open(id);
      return;
    }
    const current = this.serverTarget();
    if (current?.serverUrl !== target.serverUrl || current?.vaultId !== target.vaultId) {
      return this.explain(new Error("The Babel server or vault changed. Open the connection again."));
    }
    const previous = this.flows.get(id);
    if (previous && this.currentFlow(id, previous) && !previous.check.stopped) {
      if (!previous.opening) await runtime.open(id, previous.id);
      return;
    }
    this.stopFlow(id);
    const flow: GuidedConnection = {
      id: crypto.randomUUID(),
      entry,
      target,
      destination: this.destination(target),
      opening: true,
      check: new ConnectionCheck({
        active: () => this.currentFlow(id, flow),
        verify: async () => {
          try {
            const result = await this.handoff(id, entry, target, () => this.currentFlow(id, flow));
            return result?.status === "connected";
          } catch (error) {
            if (error instanceof ConnectionError && error.code === "reauthorize") return false;
            throw error;
          }
        },
        checking: () => this.progress(id, flow, "Checking your sign-in with the Babel server…", "Checking sign-in…"),
        waiting: () => this.progress(id, flow, "Finish signing in. This window closes automatically when Babel confirms the connection.", "Sign in to connect"),
        connected: async () => {
          this.progress(id, flow, "Connected. Closing the sign-in window…", "Connected");
          this.stopFlow(id, flow.id, false);
          new Notice(`${entry.name} connected to ${flow.destination}. Approved sources can now sync.`);
          await runtime.close(id);
        },
        failed: (error) => {
          const message = error instanceof Error ? error.message : "Could not connect. Choose Check sign-in to retry.";
          this.progress(id, flow, `${message} Choose Check sign-in to retry.`, "Connection needs attention");
        },
      }),
    };
    this.flows.set(id, flow);
    try {
      if (!(await runtime.close(id))) throw new Error("The sign-in window is still closing. Try again.");
      await this.transfers.get(id)?.catch(() => undefined);
      if (!this.currentFlow(id, flow)) return this.stopFlow(id, flow.id);
      if (!(await this.plugin.accessToken())) throw new Error("Sign in to Babel Sync before connecting server sync.");
      if (!this.currentFlow(id, flow)) return this.stopFlow(id, flow.id);
      if (!(await runtime.open(id, flow.id))) throw new Error("Could not open the sign-in window. Try again.");
      flow.opening = false;
      if (!this.currentFlow(id, flow)) return this.stopFlow(id, flow.id);
      this.progress(id, flow, "Finish signing in. This window closes automatically when Babel confirms the connection.", "Sign in to connect");
      flow.check.schedule();
    } catch (error) {
      this.stopFlow(id, flow.id);
      this.explain(error);
    }
  }

  private renderActions(id: string, content: HTMLElement): void {
    const entry = this.plugin.settings.connections[id];
    if (!entry) return;
    const flow = this.flows.get(id);
    const action = new Setting(content)
      .setName(flow ? "Automatic server sync" : "Sign-in session")
      .setDesc(flow ? `Finish signing in to connect automatically to ${flow.destination}.` : this.description(entry));
    if (flow) {
      flow.setting = action;
      action.addButton((button) =>
        button.setButtonText("Check sign-in").onClick(() => {
          if (this.currentFlow(id, flow) && !flow.check.stopped) flow.check.schedule(true);
          else void this.start(id);
        }),
      );
    }
    const target = flow?.target ?? this.serverTarget();
    if (target && new URL(entry.landingUrl).protocol === "https:") {
      action.addButton((button) =>
        button.setButtonText("Disconnect server sync").onClick(async () => {
          button.setDisabled(true);
          try {
            await this.disconnectServer(target, id);
            action.setDesc("Server sync disconnected. Show the sign-in window to connect again.");
          } catch (error) {
            this.explain(error);
          } finally {
            button.setDisabled(false);
          }
        }),
      );
    }
    action.addButton((button) =>
      button.setButtonText("Close").onClick(() => {
        this.stopFlow(id);
        void this.session?.close(id);
      }),
    );
  }

  private async handoff(id: string, entry: Connection, target: ConnectionTarget, active: () => boolean): Promise<ServerConnection | undefined> {
    if (this.transfers.has(id) || this.disconnecting.has(id)) throw new Error("This connection is being updated. Wait for it to finish.");
    const transfer = this.transfer(id, entry, target, active);
    this.transfers.set(id, transfer);
    try {
      return await transfer;
    } finally {
      this.transfers.delete(id);
    }
  }

  private async disconnectServer(target: ConnectionTarget, id: string): Promise<void> {
    if (this.disconnecting.has(id)) throw new Error("This connection is already disconnecting.");
    this.stopFlow(id);
    this.disconnecting.add(id);
    try {
      await this.transfers.get(id)?.catch(() => undefined);
      await this.request(target, id, "DELETE");
    } finally {
      this.disconnecting.delete(id);
    }
  }

  private async transfer(id: string, entry: Connection, target: ConnectionTarget, active: () => boolean): Promise<ServerConnection | undefined> {
    const runtime = this.runtime();
    if (!runtime) return;
    let result: ServerConnection | undefined;
    let failure: unknown;
    const available = await runtime.useSession(id, async (session, agent) => {
      try {
        if (!active()) throw new Error("The connection changed. Open it again.");
        const cookies = connectionCookies(await session.cookies.get({}), entry.allowedHosts);
        if (!cookies.length) throw new ConnectionError("reauthorize", "Finish signing in first.");
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
          active,
        );
      } catch (error) {
        failure = error;
      }
    });
    if (failure) throw failure;
    if (!available) throw new Error("Could not read the sign-in session. Reopen the connection and retry.");
    return result;
  }

  private async request(
    target: ConnectionTarget,
    id: string,
    method: "GET" | "POST" | "DELETE",
    body?: unknown,
    entry?: Connection,
    active?: () => boolean,
  ): Promise<ServerConnection> {
    const token = await this.plugin.accessToken();
    if (!token) throw new Error("Sign in to Babel Sync before connecting server sync.");
    const current = connectionTarget(this.plugin.settings);
    if (this.disposed || current.serverUrl !== target.serverUrl || current.vaultId !== target.vaultId) {
      throw new Error("The Babel server or vault changed. Open the connection again.");
    }
    if (entry && this.plugin.settings.connections[id] !== entry) throw new Error("The connection changed. Open it again.");
    if (active && !active()) throw new Error("This sign-in attempt was closed. Open the connection again.");
    return serverConnection(target, id, token, method, body);
  }

  private explain(error: unknown): void {
    new Notice(error instanceof Error ? error.message : "Could not update server sync. Try again.");
  }

  private pick(choose: (id: string, entry: Connection, target: ConnectionTarget | null) => void): void {
    const entries = Object.entries(this.plugin.settings.connections);
    if (entries.length === 0) this.manage();
    else {
      const targets = new Map(entries.map(([, entry]) => [entry, this.syncTarget(entry) ?? null]));
      new Picker(
        this.plugin,
        entries,
        (id) => {
          const entry = entries.find(([key]) => key === id)![1];
          choose(id, entry, targets.get(entry) ?? null);
        },
        (entry) => this.description(entry, targets.get(entry)),
      ).open();
    }
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
          instructions: (id: string) => {
            const flow = this.flows.get(id);
            return flow
              ? `Sign in in the connection window. Babel will securely send the session to ${flow.destination}, verify it and close the window automatically. You can close it to pause.`
              : "Sign in in the connection window. Your session is kept when you close it. Configure server sync in the connection settings to connect automatically.";
          },
          onSessionChanged: (id: string, flowId?: string) => {
            const flow = this.flows.get(id);
            if (flow && flow.id === flowId) flow.check.schedule();
          },
          onClosed: (id: string, flowId?: string) => {
            if (flowId) this.stopFlow(id, flowId);
          },
          reopen: (id: string) => void this.start(id),
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
    for (const id of this.flows.keys()) this.stopFlow(id);
    this.manager?.close();
    this.session?.dispose();
  }
}
