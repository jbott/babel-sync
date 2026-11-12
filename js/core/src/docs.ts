import { type BlobApi, json } from "./blobs.ts";

export async function fetchDocs(api: BlobApi, vaultId: string, ids: string[]): Promise<Map<string, Uint8Array[]>> {
  const reply = (await json(api, `${api.baseUrl}/api/vaults/${vaultId}/docs`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ ids }),
  })) as { docs: Record<string, string[]> };

  return new Map(Object.entries(reply.docs).map(([id, updates]) => [id, updates.map(fromBase64)]));
}

function fromBase64(text: string): Uint8Array {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
  return bytes;
}
