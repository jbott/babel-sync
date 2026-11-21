const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const test = require("node:test");
const ConnectorLogin = require("../src/connector-session.cjs");
const { connectionUserAgent } = require("../src/connection.ts");

class GuestSession extends EventEmitter {
  constructor() {
    super();
    this.webRequest = {
      onBeforeRequest: (...args) => {
        this.beforeRequest = args.at(-1);
      },
      onHeadersReceived: (...args) => {
        this.headersReceived = args.at(-1);
      },
    };
  }

  setPermissionRequestHandler(handler) {
    this.permissionRequest = handler;
  }

  setPermissionCheckHandler(handler) {
    this.permissionCheck = handler;
  }

  async closeAllConnections() {}

  async clearStorageData() {
    if (this.failClear) throw new Error("Synthetic storage failure");
    this.cleared = true;
  }

  async clearAuthCache() {}

  async clearCache() {}

  async request(url, method = "GET", agent) {
    this.lastRequest = { url, method, agent };
  }
}

function guestHost() {
  const partitions = new Map();
  const windows = [];
  const browsers = [];
  const session = {
    fromPartition(partition) {
      if (!partitions.has(partition)) partitions.set(partition, new GuestSession());
      return partitions.get(partition);
    },
  };

  class Browser extends EventEmitter {
    constructor(connector, partition, agent) {
      super();
      this.connector = connector;
      this.partition = partition;
      this.agent = agent;
      this.session = session.fromPartition(partition);
      this.webContents = new EventEmitter();
    }

    show() {}

    focus() {}

    loadURL(url) {
      this.loaded = this.session.request(url, "GET", this.agent);
      return this.loaded;
    }

    destroy() {
      if (!this.holdDestroy) queueMicrotask(() => this.emit("closed"));
    }
  }

  class Modal {
    constructor() {
      this.titleEl = {
        setText: (title) => {
          this.title = title;
        },
      };
      this.contentEl = {
        createEl: () => ({
          setText: (text) => {
            this.statusText = text;
          },
          addEventListener() {},
        }),
        empty: () => {
          this.closed = true;
        },
      };
      windows.push(this);
    }

    open() {
      this.onOpen();
    }

    close() {
      this.onClose();
    }
  }

  const createWindow = (...args) => {
    const browser = new Browser(...args);
    browsers.push(browser);
    return browser;
  };
  return { Modal, session, windows, browsers, createWindow };
}

test("connector sessions are isolated and disconnect waits for the sign-in window to close", async (t) => {
  const host = guestHost();
  const connectors = {
    orders: { name: "Orders", landingUrl: "https://orders.example/history", allowedHosts: ["orders.example"] },
    other: { name: "Other", landingUrl: "https://orders.example/history", allowedHosts: ["orders.example"] },
  };
  const notices = [];
  const connector = (vault) =>
    new ConnectorLogin({
      app: { vault: { adapter: { getBasePath: () => vault } } },
      ...host,
      connectors,
      getUserAgent: () => "Orders/1",
      notice: (message) => notices.push(message),
    });
  const first = connector("/test/vault-one");
  const other = connector("/test/vault-two");
  t.after(() => {
    first.dispose();
    other.dispose();
  });

  assert.equal(await first.open("orders"), true);
  const initial = host.windows.at(-1);
  const session = host.browsers.at(-1).session;
  assert.match(host.browsers.at(-1).partition, /^persist:/);
  session.permissionRequest(null, "notifications", (allowed) => assert.equal(allowed, false));
  for (const url of ["https://elsewhere.example/", "file:///etc/passwd"]) {
    session.beforeRequest({ url, resourceType: "mainFrame" }, (result) => assert.deepEqual(result, { cancel: true }));
  }
  session.beforeRequest({ url: connectors.orders.landingUrl, resourceType: "mainFrame" }, (result) => assert.deepEqual(result, { cancel: false }));
  session.headersReceived({ responseHeaders: { "Content-Disposition": ["attachment; filename=test"] } }, (result) =>
    assert.deepEqual(result, { cancel: true }),
  );
  await first.open("orders");
  assert.equal(host.windows.at(-1), initial);
  assert.equal(
    await first.useSession("orders", async (held, agent) => {
      assert.equal(held, session);
      assert.equal(agent, "Orders/1");
    }),
    true,
  );
  await first.close("orders");
  await first.open("orders");
  const reopened = host.browsers.at(-1);
  assert.equal(reopened.session, session);
  await other.open("orders");
  const otherVault = host.browsers.at(-1).session;
  assert.notEqual(otherVault, session);
  await first.open("other");
  const otherConnection = host.browsers.at(-1).session;
  assert.notEqual(otherConnection, session);

  reopened.holdDestroy = true;
  const disconnect = first.disconnect("orders");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(session.cleared, undefined);
  reopened.emit("closed");
  assert.equal(await disconnect, true);
  assert.equal(session.cleared, true);
  assert.equal(otherVault.cleared, undefined);
  assert.equal(otherConnection.cleared, undefined);
  session.failClear = true;
  assert.equal(await first.disconnect("orders"), false);
  const count = host.windows.length;
  await first.open("orders");
  assert.equal(host.windows.length, count);
  session.failClear = false;
  assert.equal(await first.disconnect("orders"), true);
  await first.open("orders");
  assert.equal(host.windows.length, count + 1);
  assert.ok(notices.some((message) => message.includes("Retry disconnecting")));
});

test("use the configured user agent for HTTPS on first navigation", async (t) => {
  const host = guestHost();

  const landingUrl = "https://orders.example/store";
  let userAgent = "Orders/1";
  const login = new ConnectorLogin({
    app: { vault: { adapter: { getBasePath: () => "/test/https-vault" } } },
    ...host,
    connectors: { orders: { name: "Orders", landingUrl, allowedHosts: ["orders.example"] } },
    getUserAgent: () => connectionUserAgent(userAgent),
    notice: assert.fail,
  });
  t.after(() => login.dispose());

  assert.equal(await login.open("orders"), true);
  const first = host.browsers.at(-1);
  await first.loaded;
  assert.equal(first.session.lastRequest.url, landingUrl);
  assert.equal(first.session.lastRequest.agent, "Orders/1");

  userAgent = "";
  assert.equal(await login.close("orders"), true);
  assert.equal(await login.open("orders"), true);
  const reopened = host.browsers.at(-1);
  await reopened.loaded;
  assert.equal(reopened.partition, first.partition);
  assert.equal(reopened.session.lastRequest.agent, connectionUserAgent());
});

test("closing the sign-in window preserves the session for handoff and reopening", async (t) => {
  const host = guestHost();
  const login = new ConnectorLogin({
    app: { vault: { adapter: { getBasePath: () => "/test/window-close-vault" } } },
    ...host,
    connectors: { orders: { name: "Orders", landingUrl: "https://orders.example/history", allowedHosts: ["orders.example"] } },
    getUserAgent: () => "Orders/1",
    notice: assert.fail,
  });
  t.after(() => login.dispose());
  await login.open("orders");
  const first = host.browsers.at(-1);
  first.emit("closed");
  assert.equal(await login.useSession("orders", async (session) => assert.equal(session, first.session)), true);
  await login.open("orders");
  assert.equal(host.windows.length, 1);
  assert.equal(host.browsers.length, 2);
  assert.equal(host.browsers.at(-1).session, first.session);
});
