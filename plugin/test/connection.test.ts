import assert from "node:assert/strict";
import test from "node:test";
import { connection, connectionUserAgent, restoreConnection } from "../src/connection.ts";

test("configure unrelated services with independent sign-in hosts", () => {
  const site = connection(" Orders ", "https://orders.example/store", [" accounts.example ", "ACCOUNTS.EXAMPLE"], " Orders/1 ");
  assert.deepEqual(site, {
    name: "Orders",
    landingUrl: "https://orders.example/store",
    allowedHosts: ["orders.example", "accounts.example"],
    userAgent: "Orders/1",
  });
  assert.deepEqual(restoreConnection(site), site);
  assert.deepEqual(connection("Office", "https://office.example:8443", [], "").allowedHosts, ["office.example"]);
});

test("restore saved loopback user agents", () => {
  const address = "http://127.0.0.1:18765/test";
  const saved = { name: "Local", landingUrl: address, allowedHosts: ["127.0.0.1"], loopbackUserAgent: "Fixture/1" };
  assert.deepEqual(restoreConnection(saved), connection("Local", address, [], "Fixture/1"));
  assert.equal(restoreConnection(saved).userAgent, "Fixture/1");
  assert.equal(connection("Local", address, [], "").userAgent, undefined);
  assert.throws(() => connection("Local", address, ["accounts.example"], ""));
});

test("use a desktop Chrome user agent for the current platform unless overridden", () => {
  assert.match(connectionUserAgent(undefined, "darwin"), /^Mozilla\/5\.0 \(Macintosh; Intel Mac OS X 10_15_7\).* Chrome\/158\.0\.0\.0 Safari\/537\.36$/);
  assert.match(connectionUserAgent(undefined, "win32"), /\(Windows NT 10\.0; Win64; x64\)/);
  assert.match(connectionUserAgent(undefined, "linux"), /\(X11; Linux x86_64\)/);
  assert.equal(connectionUserAgent("Orders/1", "darwin"), "Orders/1");
});

test("validate user agents before saving", () => {
  const address = "https://orders.example/store";
  assert.equal(connection("Orders", address, [], "  ").userAgent, undefined);
  assert.equal(connection("Orders", address, [], "a".repeat(512)).userAgent?.length, 512);
  for (const agent of ["invalid\r\nvalue", "trailing newline\n", "invalid\x7f", "café", "a".repeat(513)]) {
    assert.throws(() => connection("Orders", address, [], agent), /printable ASCII/);
  }
});

test("reject unsafe start URLs and wildcard sign-in hosts", () => {
  for (const site of ["file:///tmp/test", "http://shop.example/", "https://name:secret@shop.example", "javascript:alert(1)"]) {
    assert.throws(() => connection("Site", site, [], ""));
  }
  assert.throws(() => connection("Site", "https://shop.example", ["*.example"], ""));
});

test("restore optional signed-in verification selectors", () => {
  const saved = connection("Account", "https://fixture.example/account", [], "", " #signed-in ");
  assert.equal(saved.checkSelector, "#signed-in");
  assert.deepEqual(restoreConnection(saved), saved);
  assert.equal(connection("Account", "https://fixture.example/account", [], "").checkSelector, undefined);
  assert.throws(() => connection("Account", "https://fixture.example/account", [], "", "a".repeat(513)));
});
