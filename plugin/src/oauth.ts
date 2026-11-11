import type { Fetch } from "@babelsync/core";

export const REDIRECT_URI = "obsidian://babelsync";

const REFRESH_MARGIN_MS = 5 * 60_000;
const FORM = { "content-type": "application/x-www-form-urlencoded" };

export type Tokens = { accessToken: string; refreshToken: string; expiresAt: number };
export type Pending = { serverUrl: string; clientId: string; verifier: string; state: string };
export type Callback = { code?: string; state?: string; error?: string };

export async function registerClient(fetch: Fetch, serverUrl: string, name: string): Promise<string> {
  const response = await fetch(`${serverUrl}/oauth/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ client_name: name, redirect_uris: [REDIRECT_URI] }),
  });
  if (!response.ok) throw new Error(`The server refused to register this device (${response.status}).`);
  return (await response.json()).client_id;
}

export async function beginAuthorization(serverUrl: string, clientId: string): Promise<{ url: string; pending: Pending }> {
  const verifier = random();
  const state = random();
  const query = new URLSearchParams({
    client_id: clientId,
    redirect_uri: REDIRECT_URI,
    response_type: "code",
    scope: "vault",
    state,
    code_challenge: await challenge(verifier),
    code_challenge_method: "S256",
  });

  return { url: `${serverUrl}/oauth/authorize?${query}`, pending: { serverUrl, clientId, verifier, state } };
}

export async function finishAuthorization(fetch: Fetch, pending: Pending, callback: Callback): Promise<Tokens> {
  if (callback.error) throw new Error(callback.error === "access_denied" ? "Sign-in was cancelled." : callback.error);
  if (!callback.code || callback.state !== pending.state) throw new Error("The sign-in answer did not match the request.");

  const tokens = await request(fetch, pending.serverUrl, {
    grant_type: "authorization_code",
    code: callback.code,
    client_id: pending.clientId,
    redirect_uri: REDIRECT_URI,
    code_verifier: pending.verifier,
  });
  if (!tokens) throw new Error("The server did not accept the sign-in code.");
  return tokens;
}

export function refreshTokens(fetch: Fetch, serverUrl: string, clientId: string, refreshToken: string): Promise<Tokens | null> {
  return request(fetch, serverUrl, { grant_type: "refresh_token", refresh_token: refreshToken, client_id: clientId });
}

export async function revokeTokens(fetch: Fetch, serverUrl: string, refreshToken: string): Promise<void> {
  await fetch(`${serverUrl}/oauth/revoke`, {
    method: "POST",
    headers: FORM,
    body: new URLSearchParams({ token: refreshToken }).toString(),
  });
}

export function needsRefresh(tokens: Tokens, now = Date.now()): boolean {
  return tokens.expiresAt - now < REFRESH_MARGIN_MS;
}

async function request(fetch: Fetch, serverUrl: string, form: Record<string, string>): Promise<Tokens | null> {
  const response = await fetch(`${serverUrl}/oauth/token`, {
    method: "POST",
    headers: FORM,
    body: new URLSearchParams(form).toString(),
  });

  if (response.status === 400) return null;
  if (!response.ok) throw new Error(`The server answered ${response.status}.`);

  const body = await response.json();
  return {
    accessToken: body.access_token,
    refreshToken: body.refresh_token,
    expiresAt: Date.now() + body.expires_in * 1000,
  };
}

function random(): string {
  return encode(crypto.getRandomValues(new Uint8Array(32)));
}

async function challenge(verifier: string): Promise<string> {
  return encode(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier))));
}

function encode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
