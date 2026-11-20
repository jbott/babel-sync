const { createHash } = require("crypto");
const { isIP } = require("net");

const sessionOwners = (globalThis[Symbol.for("babel-handoff-session-owners")] ||= new Map());
const sessionClosures = (globalThis[Symbol.for("babel-handoff-session-closures")] ||= new Map());
const sessionQueues = (globalThis[Symbol.for("babel-handoff-session-queues")] ||= new Map());
const sessionFailures = (globalThis[Symbol.for("babel-handoff-session-failures")] ||= new Set());

class ConnectorLogin {
  constructor({ app, Modal, session, webContents, connectors, getUserAgent, renderActions, notice }) {
    this.app = app;
    this.Modal = Modal;
    this.session = session;
    this.webContents = webContents;
    this.connectors = connectors;
    this.getUserAgent = getUserAgent;
    this.renderActions = renderActions;
    this.notice = notice;
    this.states = new Map();
    this.disposed = false;
  }

  state(id) {
    const connector = Object.hasOwn(this.connectors, id) && this.connectors[id];
    if (!connector) throw new Error("Unknown connector");
    if (!this.states.has(id)) {
      const basePath = this.app.vault.adapter.getBasePath?.();
      if (typeof basePath !== "string" || !basePath) throw new Error("Vault path unavailable");
      const hash = createHash("sha256")
        .update(JSON.stringify([basePath, id]))
        .digest("hex");
      this.states.set(id, {
        connector,
        partition: `persist:babel-handoff-${hash}`,
        window: null,
        closePromise: Promise.resolve(),
        guestId: null,
      });
    }
    const state = this.states.get(id);
    state.connector = connector;
    return state;
  }

  enqueue(id, action) {
    let state;
    try {
      state = this.state(id);
    } catch {
      this.notice("Could not identify this vault or connector.");
      return Promise.resolve(false);
    }
    const previous = sessionQueues.get(state.partition) || Promise.resolve();
    const task = previous.then(() => action(state));
    const finished = task.catch(() => {});
    sessionQueues.set(state.partition, finished);
    void finished.then(() => {
      if (sessionQueues.get(state.partition) === finished) sessionQueues.delete(state.partition);
    });
    return task
      .then(() => true)
      .catch((error) => {
        if (error.message === "Connector window is still closing") {
          this.notice("Connector window is still closing. Retry, or restart Obsidian and retry.");
        } else {
          this.notice(`Could not manage the ${state.connector.name} connection. Retry disconnecting.`);
        }
        return false;
      });
  }

  open(id) {
    return this.enqueue(id, async (state) => {
      await this.waitForPreviousClose(state);
      if (this.disposed) return;
      if (sessionFailures.has(state.partition)) {
        this.notice(`Retry disconnecting ${state.connector.name} before opening it.`);
        return;
      }
      if (state.window) return;

      const isolatedSession = this.session.fromPartition(state.partition);
      this.configureSession(isolatedSession, state.connector, state);
      sessionOwners.set(state.partition, this);
      const login = this;
      class ConnectorModal extends this.Modal {
        onOpen() {
          this.titleEl.setText(state.connector.name);
          this.status = this.contentEl.createEl("p");
          this.status.setText(`Opening ${new URL(state.connector.landingUrl).origin}`);
          const guest = document.createElement("webview");
          this.guest = guest;
          this.started = false;
          guest.setAttribute("partition", state.partition);
          const agent = login.getUserAgent(id);
          if (agent) guest.setAttribute("useragent", agent);
          guest.setAttribute(
            "webpreferences",
            "sandbox=yes,contextIsolation=yes,nodeIntegration=no,nodeIntegrationInWorker=no,nodeIntegrationInSubFrames=no,webSecurity=yes,allowRunningInsecureContent=no",
          );
          guest.style.width = "100%";
          guest.style.height = "70vh";
          const rememberGuest = () => {
            try {
              this.guestId = guest.getWebContentsId();
            } catch {}
          };
          guest.addEventListener("did-attach", rememberGuest);
          guest.addEventListener("dom-ready", rememberGuest);
          guest.addEventListener("did-navigate", (event) => {
            try {
              const origin = new URL(event.url).origin;
              this.blocked = false;
              this.status.setText(`Current site: ${origin}`);
            } catch {
              this.status.setText("Current site could not be verified.");
            }
          });
          guest.addEventListener("did-fail-load", (event) => {
            if (event.isMainFrame && event.errorCode !== -3) {
              if (!this.blocked) {
                let origin = "the site";
                try {
                  origin = new URL(event.validatedURL).origin;
                } catch {}
                this.status.setText(`Could not load ${origin}.`);
              }
              login.notice(`Could not load ${state.connector.name}.`);
            }
          });
          login.renderActions?.(id, this.contentEl);
          this.contentEl.appendChild(guest);
          if (typeof guest.loadURL !== "function") {
            this.close();
            login.notice("This Obsidian installation does not support isolated connector windows.");
            return;
          }
          this.started = true;
          guest.setAttribute("src", state.connector.landingUrl);
        }

        onClose() {
          const guest = this.guest;
          try {
            this.guestId ||= guest.getWebContentsId();
          } catch {}
          state.guestId = this.guestId || null;
          state.closePromise = this.started ? new Promise((resolve) => guest.addEventListener("destroyed", resolve, { once: true })) : Promise.resolve();
          this.contentEl.empty();
          if (state.window === this) state.window = null;
        }
      }
      const modal = new ConnectorModal(this.app);
      state.window = modal;
      try {
        modal.open();
      } catch (error) {
        this.closeWindow(state);
        throw error;
      }
    });
  }

  useSession(id, action) {
    return this.enqueue(id, async (state) => {
      await this.waitForPreviousClose(state);
      if (this.disposed || sessionFailures.has(state.partition)) throw new Error("Connector is unavailable");
      const isolatedSession = this.session.fromPartition(state.partition);
      this.configureSession(isolatedSession, state.connector, state);
      sessionOwners.set(state.partition, this);
      await action(isolatedSession, this.getUserAgent(id));
    });
  }

  allowedNavigation(value, connector) {
    try {
      const url = new URL(value);
      const landing = new URL(connector.landingUrl);
      if (url.username || url.password || !connector.allowedHosts.includes(url.hostname)) return false;
      if (landing.protocol === "http:" && landing.hostname === "127.0.0.1") return url.origin === landing.origin;
      return url.protocol === "https:" && (url.origin === landing.origin || !url.port);
    } catch {
      return false;
    }
  }

  configureSession(isolatedSession, connector, state) {
    isolatedSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
    isolatedSession.webRequest.onBeforeRequest({ urls: ["<all_urls>"] }, (details, callback) => {
      let url;
      try {
        url = new URL(details.url);
      } catch {
        callback({ cancel: true });
        return;
      }
      const landing = new URL(connector.landingUrl);
      const local = landing.protocol === "http:" && landing.hostname === "127.0.0.1";
      const remote =
        url.protocol === "https:" && !isIP(url.hostname.replace(/^\[|\]$/g, "")) && url.hostname !== "localhost" && !url.hostname.endsWith(".localhost");
      const allowedResource = !url.username && !url.password && (local ? url.origin === landing.origin : remote || this.allowedNavigation(url.href, connector));
      const allowed = allowedResource && (details.resourceType !== "mainFrame" || this.allowedNavigation(details.url, connector));
      if (details.resourceType === "mainFrame" && state.window?.status) {
        state.window.blocked = !allowed;
        state.window.status.setText(allowed ? `Opening ${url.origin}` : `Blocked navigation to ${url.origin}.`);
      }
      callback({ cancel: !allowed });
    });
    isolatedSession.webRequest.onHeadersReceived({ urls: ["<all_urls>"] }, (details, callback) => {
      const disposition = Object.entries(details.responseHeaders || {}).find(([name]) => name.toLowerCase() === "content-disposition");
      const attachment = disposition && disposition[1].some((value) => /^\s*attachment(?:\s*;|\s*$)/i.test(value));
      callback({ cancel: Boolean(attachment) });
    });
  }

  closeWindow(state) {
    const window = state.window;
    state.window = null;
    if (window) window.close();
    return state.closePromise;
  }

  async waitForClose(state) {
    let timer;
    let poll;
    const closing = state.closePromise;
    try {
      await Promise.race([
        closing,
        new Promise((resolve, reject) => {
          timer = setTimeout(() => reject(new Error("Connector window is still closing")), 3000);
          if (state.guestId && this.webContents) {
            const check = () => {
              try {
                const guest = this.webContents.fromId(state.guestId);
                if (!guest || guest.isDestroyed()) resolve();
              } catch {}
            };
            poll = setInterval(check, 100);
            check();
          }
        }),
      ]);
      if (state.closePromise === closing) state.closePromise = Promise.resolve();
    } finally {
      clearTimeout(timer);
      clearInterval(poll);
    }
  }

  async waitForPreviousClose(state) {
    const closure = sessionClosures.get(state.partition);
    if (closure) {
      await closure.login.waitForClose(closure.state);
      if (sessionClosures.get(state.partition) === closure) sessionClosures.delete(state.partition);
    }
    if (closure?.state !== state) await this.waitForClose(state);
  }

  close(id) {
    return this.enqueue(id, async (state) => {
      this.closeWindow(state);
      await this.waitForClose(state);
    });
  }

  disconnect(id) {
    return this.enqueue(id, async (state) => {
      try {
        this.closeWindow(state);
        await this.waitForPreviousClose(state);
        const isolatedSession = this.session.fromPartition(state.partition);
        await isolatedSession.closeAllConnections();
        await isolatedSession.clearStorageData();
        await isolatedSession.clearCache();
        await isolatedSession.clearAuthCache();
        sessionFailures.delete(state.partition);
        this.notice(`${state.connector.name} connection cleared.`);
      } catch (error) {
        sessionFailures.add(state.partition);
        throw error;
      }
    });
  }

  dispose() {
    this.disposed = true;
    for (const state of this.states.values()) {
      this.closeWindow(state);
      void this.waitForClose(state)
        .then(() => {
          if (sessionOwners.get(state.partition) !== this) return;
          const isolatedSession = this.session.fromPartition(state.partition);
          isolatedSession.webRequest.onBeforeRequest(null);
          isolatedSession.webRequest.onHeadersReceived(null);
          isolatedSession.setPermissionRequestHandler(null);
          sessionOwners.delete(state.partition);
        })
        .catch(() => {});
    }
  }
}

module.exports = ConnectorLogin;
