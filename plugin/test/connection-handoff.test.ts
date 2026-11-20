import assert from "node:assert/strict";
import test from "node:test";
import { connectionCookies, connectionTarget, serverConnection } from "../src/connection-handoff.ts";

test("handoff includes only cookies applicable to the declared connection hosts", () => {
  const cookies = [
    { domain: ".fixture.example", hostOnly: false },
    { domain: "app.fixture.example", hostOnly: true },
    { domain: "fixture.example", hostOnly: true },
    { domain: "other.fixture.example", hostOnly: false },
    { domain: ".fixture.example.evil.test", hostOnly: false },
  ].map((cookie) => ({ ...cookie, name: "session", value: "fixture-value" }));
  assert.deepEqual(connectionCookies(cookies, ["app.fixture.example"]), cookies.slice(0, 2));
});

test("server handoff requires a configured vault and a trusted transport", () => {
  assert.deepEqual(connectionTarget({ serverUrl: "https://babel.example/base/", vaultId: "vault" }), {
    serverUrl: "https://babel.example/base",
    vaultId: "vault",
  });
  for (const serverUrl of [
    "http://babel.example",
    "https://user:password@babel.example",
    "https://babel.example/#elsewhere",
    "https://babel.example/?token=secret",
  ]) {
    assert.throws(() => connectionTarget({ serverUrl, vaultId: "vault" }));
  }
  assert.throws(() => connectionTarget({ serverUrl: "https://babel.example", vaultId: "" }));
});

test("handoff binds the request to the selected vault and refuses redirects", async (context) => {
  context.mock.method(globalThis, "fetch", async (url: string, options: RequestInit) => {
    assert.equal(url, "https://babel.example/api/vaults/vault/connections/connection");
    assert.equal(options.method, "POST");
    assert.equal(options.redirect, "error");
    assert.equal(options.credentials, "omit");
    assert.deepEqual(options.headers, { authorization: "Bearer fixture-token", "content-type": "application/json" });
    assert.deepEqual(JSON.parse(options.body as string), { cookies: [], user_agent: "fixture-agent" });
    return new Response(JSON.stringify({ status: "connected" }), { status: 200 });
  });
  assert.deepEqual(
    await serverConnection({ serverUrl: "https://babel.example", vaultId: "vault" }, "connection", "fixture-token", "POST", {
      cookies: [],
      user_agent: "fixture-agent",
    }),
    { status: "connected" },
  );
});

test("failed handoff never displays a response body that could contain session data", async (context) => {
  context.mock.method(globalThis, "fetch", async () => new Response("sensitive-session-value", { status: 422 }));
  await assert.rejects(
    serverConnection({ serverUrl: "https://babel.example", vaultId: "vault" }, "connection", "fixture-token", "POST"),
    /signed-in check failed/,
  );
});
