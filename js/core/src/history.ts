import { type BlobApi, json } from "./blobs.ts";

export type VersionSummary = {
  id: number;
  saved_at: string;
  bytes: number;
  author: string | null;
  added: number | null;
  removed: number | null;
  earliest: boolean;
};

export type ChangeKind = "same" | "removed" | "added";

export type ChangedLine = {
  kind: ChangeKind;
  old: number | null;
  new: number | null;
  segments: [ChangeKind, string][];
};

export type Hunk = { old_start: number; new_start: number; lines: ChangedLine[] };

export type Changes = { added: number; removed: number; hunks: Hunk[] };

export type VersionDetail = { id: number; saved_at: string; text: string; changes: Changes };

export type Against = "previous" | "now";

function base(api: BlobApi, vaultId: string, entryId: string): string {
  return `${api.baseUrl}/api/vaults/${vaultId}/notes/${entryId}/versions`;
}

export async function listVersions(api: BlobApi, vaultId: string, entryId: string): Promise<VersionSummary[]> {
  const reply = (await json(api, base(api, vaultId, entryId), { method: "GET" })) as { versions: VersionSummary[] };
  return reply.versions;
}

export async function compareVersion(api: BlobApi, vaultId: string, entryId: string, id: number, against: Against): Promise<VersionDetail> {
  return (await json(api, `${base(api, vaultId, entryId)}/${id}?against=${against}`, { method: "GET" })) as VersionDetail;
}

export async function restoreVersion(api: BlobApi, vaultId: string, entryId: string, id: number): Promise<void> {
  await json(api, `${base(api, vaultId, entryId)}/${id}/restore`, { method: "POST" });
}
