import assert from "node:assert/strict";
import { test } from "node:test";
import { BabelSyncClient } from "@babelsync/core";
import { beginAuthorization, finishAuthorization, needsRefresh, refreshTokens, registerClient, revokeTokens } from "../src/oauth.ts";

const serverUrl = process.env.BABELSYNC_URL!;
const vaultId = process.env.BABELSYNC_VAULT_IDS!.split(",")[0];

async function approveInBrowser(url: string): Promise<Record<string, string>> {
  const page = await fetch(url);
  const cookie = page.headers
    .getSetCookie()
    .map((value) => value.split(";")[0])
    .join("; ");
  const html = await page.text();
  const fields = new URLSearchParams({ decision: "approve" });
  for (const [, name, value] of html.matchAll(/<input[^>]*name="([^"]+)"[^>]*value="([^"]*)"/g)) {
    fields.set(name, value.replaceAll("&amp;", "&"));
  }

  const decided = await fetch(`${serverUrl}/oauth/authorize`, {
    method: "POST",
    redirect: "manual",
    headers: { "content-type": "application/x-www-form-urlencoded", cookie },
    body: fields.toString(),
  });

  assert.equal(decided.status, 302);
  const location = decided.headers.get("location")!;
  assert.ok(location.startsWith("obsidian://babelsync?"), location);
  return Object.fromEntries(new URLSearchParams(location.split("?")[1]));
}

async function vaults(accessToken: string): Promise<number> {
  const response = await fetch(`${serverUrl}/api/vaults`, {
    headers: { authorization: `Bearer ${accessToken}`, origin: "app://obsidian.md" },
  });
  return response.status;
}

test("a device signs in, syncs with its token, refreshes it and signs out", async () => {
  const clientId = await registerClient(fetch, serverUrl, "Obsidian (test device)");
  const { url, pending } = await beginAuthorization(serverUrl, clientId);
  const callback = await approveInBrowser(url);

  await assert.rejects(finishAuthorization(fetch, pending, { ...callback, state: "forged" }));
  const tokens = await finishAuthorization(fetch, pending, callback);
  assert.equal(needsRefresh(tokens), false);
  assert.equal(needsRefresh(tokens, tokens.expiresAt - 60_000), true);
  assert.equal(await vaults(tokens.accessToken), 200);

  const client = new BabelSyncClient({ baseUrl: serverUrl, token: () => tokens.accessToken, transport: WebSocket });
  client.connect();
  const vault = client.vault(vaultId);
  await vault.whenJoined();
  vault.close();
  await client.disconnect();

  const refreshed = await refreshTokens(fetch, serverUrl, clientId, tokens.refreshToken);
  assert.ok(refreshed);
  assert.equal(await vaults(tokens.accessToken), 401);
  assert.equal(await vaults(refreshed.accessToken), 200);

  await revokeTokens(fetch, serverUrl, refreshed.refreshToken);
  assert.equal(await vaults(refreshed.accessToken), 401);
  assert.equal(await refreshTokens(fetch, serverUrl, clientId, refreshed.refreshToken), null);
});

test("declining is reported as a cancelled sign-in", async () => {
  const clientId = await registerClient(fetch, serverUrl, "Obsidian (test device)");
  const { pending } = await beginAuthorization(serverUrl, clientId);
  await assert.rejects(finishAuthorization(fetch, pending, { error: "access_denied", state: pending.state }), /cancelled/);
});
