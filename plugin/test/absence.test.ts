import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { test } from "node:test";
import { BabelSyncClient } from "@babelsync/core";
import { SyncEngine } from "../src/engine.ts";
import { type LocalEntry, MemoryFs, MemoryStore } from "../src/fs.ts";

const baseUrl = process.env.BABELSYNC_URL!;
const token = process.env.BABELSYNC_TOKEN!;
const vaultId = process.env.BABELSYNC_VAULT_IDS!.split(",")[0];
const phase = process.env.BABELSYNC_PHASE!;
const statePath = process.env.BABELSYNC_STATE!;

type Saved = {
  seq: number;
  entries: (Omit<LocalEntry, "doc"> & { doc?: number[] })[];
  files: { path: string; text: string; mtime: number }[];
};

async function save(fs: MemoryFs, store: MemoryStore): Promise<void> {
  const saved: Saved = {
    seq: store.seq,
    entries: [...store.entries.values()].map((entry) => ({ ...entry, doc: entry.doc && [...entry.doc] })),
    files: [...fs.files.entries()].map(([path, file]) => ({
      path,
      text: new TextDecoder().decode(file.data),
      mtime: file.mtime,
    })),
  };
  await writeFile(statePath, JSON.stringify(saved));
}

async function load(): Promise<{ fs: MemoryFs; store: MemoryStore }> {
  const saved: Saved = JSON.parse(await readFile(statePath, "utf8"));
  const fs = new MemoryFs();
  const store = new MemoryStore();
  store.seq = saved.seq;
  for (const entry of saved.entries) {
    store.entries.set(entry.id, { ...entry, doc: entry.doc && Uint8Array.from(entry.doc) });
  }
  for (const file of saved.files) {
    fs.files.set(file.path, { data: new TextEncoder().encode(file.text), mtime: file.mtime });
  }
  return { fs, store };
}

async function synced(fs: MemoryFs, store: MemoryStore): Promise<() => Promise<void>> {
  const client = new BabelSyncClient({ baseUrl, token: () => token, transport: WebSocket });
  const engine = new SyncEngine({ client, vaultId, fs, store, device: "phone" });
  client.connect();
  await engine.start();
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("never synced")), 15000);
    engine.on("status", (status) => {
      if (status !== "synced") return;
      clearTimeout(timer);
      resolve();
    });
  });
  await engine.idle();

  return async () => {
    await engine.stop();
    await client.disconnect();
  };
}

test("before: the device syncs three notes and goes away", { skip: phase !== "before" }, async () => {
  const fs = new MemoryFs();
  const store = new MemoryStore();
  for (const name of ["kept", "untouched", "edited"]) await fs.writeText(`${name}.md`, `${name}\n`);

  const stop = await synced(fs, store);
  await stop();

  assert.equal(store.entries.size, 3);
  await fs.writeText("edited.md", "edited\nwhile away\n");
  await save(fs, store);
});

test("after: purged notes are dropped unless they were changed here", { skip: phase !== "after" }, async () => {
  const { fs, store } = await load();

  const stop = await synced(fs, store);
  await stop();

  assert.deepEqual([...fs.files.keys()].sort(), ["edited.md", "kept.md"]);
  assert.equal(await fs.readText("edited.md"), "edited\nwhile away\n");
});
