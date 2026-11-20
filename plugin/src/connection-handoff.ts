export type ConnectionTarget = { serverUrl: string; vaultId: string };
export type ServerConnection = { status: "connected" | "disconnected" };
export type SessionCookie = { domain: string; hostOnly?: boolean; [key: string]: unknown };

export function connectionCookies(cookies: SessionCookie[], hosts: string[]): SessionCookie[] {
  return cookies.filter((cookie) => {
    const domain = cookie.domain.replace(/^\./, "").toLowerCase();
    return hosts.some((host) => host === domain || (cookie.hostOnly !== true && host.endsWith("." + domain)));
  });
}

export function connectionTarget(settings: ConnectionTarget): ConnectionTarget {
  if (!settings.serverUrl || !settings.vaultId) throw new Error("Connect this vault to Babel Sync first.");
  const server = new URL(settings.serverUrl);
  const local = server.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(server.hostname);
  if ((server.protocol !== "https:" && !local) || server.username || server.password || server.search || server.hash) {
    throw new Error("Server sync requires an HTTPS Babel server address.");
  }
  return { serverUrl: server.href.replace(/\/$/, ""), vaultId: settings.vaultId };
}

export async function serverConnection(
  target: ConnectionTarget,
  id: string,
  token: string,
  method: "GET" | "POST" | "DELETE",
  body?: unknown,
): Promise<ServerConnection> {
  const url = `${target.serverUrl}/api/vaults/${encodeURIComponent(target.vaultId)}/connections/${encodeURIComponent(id)}`;
  const options: RequestInit = {
    method,
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    credentials: "omit",
    redirect: "error",
    signal: AbortSignal.timeout(120_000),
  };
  if (method === "POST") options.body = JSON.stringify(body);
  let response: Response;
  try {
    response = await fetch(url, options);
  } catch {
    throw new Error("Could not reach the Babel server. Check the connection and retry.");
  }
  if (response.status === 401) throw new Error("Sign in to Babel Sync again.");
  if (response.status === 403) throw new Error("Only a vault administrator can manage server connections.");
  if (response.status === 409) throw new Error("The server connection changed. Open it again and retry.");
  if (response.status === 422) throw new Error("The signed-in check failed for this session. Sign in in the connection and retry.");
  if (!response.ok) throw new Error(`Could not update server sync. The Babel server answered ${response.status}.`);
  const result: unknown = await response.json();
  if (!result || typeof result !== "object" || !("status" in result) || !["connected", "disconnected"].includes(String(result.status))) {
    throw new Error("The Babel server returned an unexpected connection status.");
  }
  return result as ServerConnection;
}
