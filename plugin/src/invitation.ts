export type Invitation = { server: string; vaultId: string; vaultName: string; files?: number };

export function normalizeServer(value: string): string | null {
  const trimmed = value.trim().replace(/\/+$/, "");
  if (!trimmed) return null;

  try {
    const url = new URL(/^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`);
    if (url.protocol !== "https:" && url.protocol !== "http:") return null;
    return `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
  } catch {
    return null;
  }
}

export function hostOf(server: string): string {
  try {
    return new URL(server).host;
  } catch {
    return server;
  }
}

export function readInvitation(params: Record<string, string | undefined>): Invitation | null {
  const server = normalizeServer(params.server ?? "");
  const vaultId = (params.id ?? "").trim();
  if (!server || !/^[0-9a-f-]{8,64}$/i.test(vaultId)) return null;
  return { server, vaultId, vaultName: (params.name ?? "").trim().slice(0, 200) };
}
