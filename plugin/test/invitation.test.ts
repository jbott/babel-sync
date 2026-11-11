import assert from "node:assert/strict";
import { test } from "node:test";
import { hostOf, normalizeServer, readInvitation } from "../src/invitation.ts";

const ID = "f53bc715-a14c-468e-9b06-e6d61a233d99";

test("a bare host becomes an https address without a trailing slash", () => {
  assert.equal(normalizeServer(" notes.example.com/ "), "https://notes.example.com");
  assert.equal(normalizeServer("http://localhost:4000"), "http://localhost:4000");
  assert.equal(normalizeServer("https://example.com/sync//"), "https://example.com/sync");
});

test("addresses that are not web addresses are refused", () => {
  assert.equal(normalizeServer(""), null);
  assert.equal(normalizeServer("file:///etc/passwd"), null);
  assert.equal(normalizeServer("javascript://alert(1)"), null);
});

test("a connect link names a server and a vault", () => {
  assert.deepEqual(readInvitation({ server: "https://notes.example.com/", id: ID, name: "Notes" }), {
    server: "https://notes.example.com",
    vaultId: ID,
    vaultName: "Notes",
  });
});

test("a connect link without a usable server or vault is refused", () => {
  assert.equal(readInvitation({ id: ID }), null);
  assert.equal(readInvitation({ server: "https://notes.example.com" }), null);
  assert.equal(readInvitation({ server: "https://notes.example.com", id: "../../etc" }), null);
  assert.equal(readInvitation({ server: "obsidian://x", id: ID }), null);
});

test("the host is what people are shown", () => {
  assert.equal(hostOf("https://notes.example.com/sync"), "notes.example.com");
});
