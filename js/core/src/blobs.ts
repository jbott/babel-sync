import { toHex } from "./encoding.ts";

export type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

export type BlobApi = {
  baseUrl: string;
  token?: () => string | undefined;
  fetch?: Fetch;
};

export const PART_SIZE = 8 * 1024 * 1024;

type BeginReply = { status: "exists" } | { status: "upload"; id: string; part_size: number; missing: number[] };

export async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data as BufferSource));
}

export async function blobHash(data: Uint8Array, partSize = PART_SIZE): Promise<string> {
  const digests: Uint8Array[] = [];
  for (const part of parts(data, partSize)) digests.push(await sha256(part));

  const joined = new Uint8Array(digests.length * 32);
  digests.forEach((digest, index) => joined.set(digest, index * 32));
  return toHex(await sha256(joined));
}

export async function uploadBlob(
  api: BlobApi,
  vaultId: string,
  data: Uint8Array,
  onProgress?: (sentBytes: number, totalBytes: number) => void,
): Promise<string> {
  const hash = await blobHash(data);
  const base = `${api.baseUrl}/api/vaults/${vaultId}/uploads`;

  const begin = (await json(api, base, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ hash, size: data.byteLength }),
  })) as BeginReply;

  if (begin.status === "exists") return hash;
  if (begin.part_size !== PART_SIZE) throw new Error(`unsupported part size ${begin.part_size}`);

  const chunks = parts(data, begin.part_size);
  let sent = data.byteLength - begin.missing.reduce((sum, n) => sum + chunks[n - 1].byteLength, 0);

  for (const number of begin.missing) {
    const chunk = chunks[number - 1];
    await send(api, `${base}/${begin.id}/parts/${number}`, {
      method: "PUT",
      headers: { "content-type": "application/octet-stream" },
      body: chunk as BodyInit,
    });
    sent += chunk.byteLength;
    onProgress?.(sent, data.byteLength);
  }

  await json(api, `${base}/${begin.id}/complete`, { method: "POST" });
  return hash;
}

export async function downloadBlob(api: BlobApi, vaultId: string, hash: string): Promise<Uint8Array> {
  const response = await send(api, blobUrl(api, vaultId, hash), { method: "GET" });
  const data = new Uint8Array(await response.arrayBuffer());

  if ((await blobHash(data)) !== hash) throw new Error(`blob ${hash} arrived corrupted`);
  return data;
}

export function blobUrl(api: BlobApi, vaultId: string, hash: string): string {
  return `${api.baseUrl}/api/vaults/${vaultId}/blobs/${hash}`;
}

function parts(data: Uint8Array, partSize: number): Uint8Array[] {
  if (data.byteLength === 0) return [data];

  const out: Uint8Array[] = [];
  for (let offset = 0; offset < data.byteLength; offset += partSize) {
    out.push(data.subarray(offset, Math.min(offset + partSize, data.byteLength)));
  }
  return out;
}

async function send(api: BlobApi, url: string, init: RequestInit): Promise<Response> {
  const headers = new Headers(init.headers);
  const token = api.token?.();
  if (token) headers.set("authorization", `Bearer ${token}`);

  const response = await (api.fetch ?? fetch)(url, { ...init, headers });
  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new Error(`${init.method} ${url} failed with ${response.status} ${detail}`);
  }
  return response;
}

export async function json(api: BlobApi, url: string, init: RequestInit): Promise<unknown> {
  return (await send(api, url, init)).json();
}
