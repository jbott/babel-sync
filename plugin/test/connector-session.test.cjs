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
  const session = {
    fromPartition(partition) {
      if (!partitions.has(partition)) partitions.set(partition, new GuestSession());
      return partitions.get(partition);
    },
  };

  class Guest extends EventEmitter {
    constructor() {
      super();
      this.attributes = {};
      this.style = {};
    }

    addEventListener(name, listener, options) {
      if (options?.once) this.once(name, listener);
      else this.on(name, listener);
    }

    loadURL() {}

    setAttribute(name, value) {
      this.attributes[name] = value;
      if (name === "src") {
        this.session = session.fromPartition(this.attributes.partition);
        this.loaded = this.session.request(value, "GET", this.attributes.useragent).then((page) => {
          this.page = page;
        });
      }
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
        createEl: (tag) => {
          assert.equal(tag, "p");
          return {
            setText: (text) => {
              this.statusText = text;
            },
          };
        },
        appendChild: (guest) => {
          this.guest = guest;
          guest.emit("did-attach");
        },
        empty: () => {
          this.closed = true;
          if (!this.guest.holdDestroy) queueMicrotask(() => this.guest.emit("destroyed"));
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

  const document = {
    createElement: (tag) => {
      assert.equal(tag, "webview");
      return new Guest();
    },
  };
  return { Modal, session, windows, document };
}

test("connector sessions are isolated and disconnect waits for the guest to close", async (t) => {
  const host = guestHost();
  const originalDocument = global.document;
  global.document = host.document;
  t.after(() => {
    global.document = originalDocument;
  });
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
  const session = initial.guest.session;
  assert.match(initial.guest.attributes.partition, /^persist:/);
  assert.match(initial.guest.attributes.webpreferences, /sandbox=yes/);
  assert.match(initial.guest.attributes.webpreferences, /contextIsolation=yes/);
  assert.match(initial.guest.attributes.webpreferences, /nodeIntegration=no/);
  assert.equal(initial.guest.attributes.allowpopups, undefined);
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
  const reopened = host.windows.at(-1);
  assert.equal(reopened.guest.session, session);
  await other.open("orders");
  const otherVault = host.windows.at(-1).guest.session;
  assert.notEqual(otherVault, session);
  await first.open("other");
  const otherConnection = host.windows.at(-1).guest.session;
  assert.notEqual(otherConnection, session);

  reopened.guest.holdDestroy = true;
  const disconnect = first.disconnect("orders");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(session.cleared, undefined);
  reopened.guest.emit("destroyed");
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
  const originalDocument = global.document;
  global.document = host.document;
  t.after(() => {
    global.document = originalDocument;
  });

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
  const first = host.windows.at(-1).guest;
  await first.loaded;
  assert.equal(first.session.lastRequest.url, landingUrl);
  assert.equal(first.session.lastRequest.agent, "Orders/1");

  userAgent = "";
  assert.equal(await login.close("orders"), true);
  assert.equal(await login.open("orders"), true);
  const reopened = host.windows.at(-1).guest;
  await reopened.loaded;
  assert.equal(reopened.attributes.partition, first.attributes.partition);
  assert.equal(reopened.session.lastRequest.agent, connectionUserAgent());
});
