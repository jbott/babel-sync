const { createHash } = require("crypto");
const { isIP } = require("net");
const { allowedNavigation } = require("./connector-navigation.cjs");

const sessionOwners = (globalThis[Symbol.for("babel-handoff-session-owners")] ||= new Map());
const sessionClosures = (globalThis[Symbol.for("babel-handoff-session-closures")] ||= new Map());
const sessionQueues = (globalThis[Symbol.for("babel-handoff-session-queues")] ||= new Map());
const sessionFailures = (globalThis[Symbol.for("babel-handoff-session-failures")] ||= new Set());

class ConnectorLogin {
  constructor({ app, Modal, session, createWindow, connectors, getUserAgent, renderActions, notice }) {
    this.app = app;
    this.Modal = Modal;
    this.session = session;
    this.createWindow = createWindow;
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
        browser: null,
        browserClosed: Promise.resolve(),
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
      if (state.window) {
        state.window.showLogin();
        return;
      }

      const isolatedSession = this.session.fromPartition(state.partition);
      this.configureSession(isolatedSession, state.connector, state);
      sessionOwners.set(state.partition, this);
      const login = this;
      class ConnectorModal extends this.Modal {
        onOpen() {
          this.titleEl.setText(state.connector.name);
          this.status = this.contentEl.createEl("p");
          this.contentEl.createEl("p", { text: "Sign in in the connection window, then return here to connect server sync." });
          this.contentEl.createEl("button", { text: "Show sign-in window" }).addEventListener("click", () => void login.open(id));
          login.renderActions?.(id, this.contentEl);
          this.showLogin();
        }

        showLogin() {
          if (state.browser) {
            state.browser.show();
            state.browser.focus();
            return;
          }
          const browser = login.createWindow(state.connector, state.partition, login.getUserAgent(id));
          state.browser = browser;
          state.browserClosed = new Promise((resolve) => {
            browser.once("closed", () => {
              if (state.browser === browser) state.browser = null;
              this.status.setText("Sign-in window closed. You can connect server sync or reopen the window.");
              resolve();
            });
          });
          this.status.setText(`Opening ${new URL(state.connector.landingUrl).origin}`);
          browser.webContents.on("did-navigate", (_event, address) => {
            try {
              this.blocked = false;
              this.status.setText(`Current site: ${new URL(address).origin}`);
            } catch {
              this.status.setText("Current site could not be verified.");
            }
          });
          browser.webContents.on("did-fail-load", (_event, errorCode, _description, address, mainFrame) => {
            if (mainFrame && errorCode !== -3) {
              if (!this.blocked) {
                let origin = "the site";
                try {
                  origin = new URL(address).origin;
                } catch {}
                this.status.setText(`Could not load ${origin}.`);
              }
              login.notice(`Could not load ${state.connector.name}.`);
            }
          });
          browser.show();
          void browser.loadURL(state.connector.landingUrl).catch(() => {});
        }

        onClose() {
          if (state.browser) {
            state.closePromise = state.browserClosed;
            sessionClosures.set(state.partition, { login, state });
            state.browser.destroy();
          }
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
      const allowedResource = !url.username && !url.password && (local ? url.origin === landing.origin : remote || allowedNavigation(url.href, connector));
      const allowed = allowedResource && (details.resourceType !== "mainFrame" || allowedNavigation(details.url, connector));
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
    const closing = state.closePromise;
    try {
      await Promise.race([
        closing,
        new Promise((_resolve, reject) => {
          timer = setTimeout(() => reject(new Error("Connector window is still closing")), 3000);
        }),
      ]);
      if (state.closePromise === closing) state.closePromise = Promise.resolve();
    } finally {
      clearTimeout(timer);
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
          if (sessionClosures.get(state.partition)?.state === state) sessionClosures.delete(state.partition);
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
