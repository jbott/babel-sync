import assert from "node:assert/strict";
import { test } from "node:test";
import { BabelSyncClient } from "@babelsync/core";
import { SyncEngine } from "../src/engine.ts";
import { MemoryFs, MemoryStore } from "../src/fs.ts";
import { FlakyStore, STORE_FAULT } from "./faults.ts";

const baseUrl = process.env.BABELSYNC_URL!;
const token = process.env.BABELSYNC_TOKEN!;
const vaultIds = process.env.BABELSYNC_VAULT_IDS!.split(",");
const steps = Number(process.env.BABELSYNC_STEPS ?? 70);

const NAMES = ["laptop", "phone", "tablet"];
const PATHS = ["inbox.md", "todo.md", "Daily/monday.md", "Daily/tuesday.md", "Places/cafe.md", "Places/park.md", "Places/list.base", "Attachments/photo.png"];

type Disk = { fs: MemoryFs; store: MemoryStore };
type Ledger = { added: string[]; discarded: string[] };

async function discard(fs: MemoryFs, path: string, ledger: Ledger): Promise<void> {
  if (path.endsWith(".png") || !fs.files.has(path)) return;
  ledger.discarded.push(await fs.readText(path));
}

function overwriting(name: string, step: number): string {
  const count = [...String(step)].map((digit) => "ABCDEFGHIJ"[Number(digit)]).join("");
  return `${name.toUpperCase()}_WROTE_${count}!`;
}

function added(text: string): string {
  return text.replace(/[A-Z_!]/g, "");
}

function occurrences(text: string, part: string): number {
  return text.split(part).length - 1;
}
type Device = Disk & { name: string; flaky: FlakyStore | null; client: BabelSyncClient; engine: SyncEngine; errors: string[]; log: string[] };

function random(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let mixed = Math.imul(state ^ (state >>> 15), 1 | state);
    mixed = (mixed + Math.imul(mixed ^ (mixed >>> 7), 61 | mixed)) ^ mixed;
    return ((mixed ^ (mixed >>> 14)) >>> 0) / 4294967296;
  };
}

function copyOf({ fs, store }: Disk): Disk {
  const disk = { fs: new MemoryFs(), store: new MemoryStore() };
  for (const [path, file] of fs.files) disk.fs.files.set(path, { data: file.data.slice(), mtime: file.mtime });
  for (const folder of fs.folders) disk.fs.folders.add(folder);
  Object.assign(disk.fs, { clock: (fs as unknown as { clock: number }).clock });
  for (const [id, entry] of store.entries) disk.store.entries.set(id, { ...entry });
  disk.store.seq = store.seq;
  return disk;
}

function watch(fs: MemoryFs, engine: SyncEngine): void {
  fs.watcher = (event) => {
    if (event.type === "changed") engine.localChanged(event.path);
    else if (event.type === "deleted") engine.localDeleted(event.path);
    else if (event.type === "folderCreated") engine.localFolderCreated(event.path);
    else if (event.type === "renamed") engine.localRenamed(event.from, event.path);
  };
}

async function boot(name: string, vaultId: string, disk: Disk, story: string[] = [], faults?: () => number): Promise<Device> {
  const client = new BabelSyncClient({ baseUrl, token: () => token, transport: WebSocket });
  const errors: string[] = [];
  const flaky = faults ? new FlakyStore(disk.store, faults) : null;
  const engine = new SyncEngine({
    client,
    vaultId,
    fs: disk.fs,
    store: flaky ?? disk.store,
    device: name,
    stateRetryMs: 20,
    sessionIdleMs: 50,
    settleMs: 50,
    retryMs: 200,
  });
  const log: string[] = [];
  engine.on("error", (message) => errors.push(message));
  watch(disk.fs, engine);
  engine.on("log", (line) => {
    log.push(line);
    story.push(`    ${name}: ${line}`);
  });
  client.connect();
  await engine.start();
  return { name, ...disk, flaky, client, engine, errors, log };
}

function crash(device: Device): Disk {
  const disk = copyOf(device);
  void device.client.disconnect();
  void device.engine.stop().catch(() => {});
  device.flaky?.shut();
  return disk;
}

function contents(fs: MemoryFs): Map<string, string> {
  const seen = new Map<string, string>();
  for (const [path, file] of fs.files) seen.set(path, Buffer.from(file.data).toString("base64"));
  return seen;
}

function difference(one: Map<string, string>, other: Map<string, string>): string[] {
  const paths = new Set([...one.keys(), ...other.keys()]);
  return [...paths].filter((path) => one.get(path) !== other.get(path)).sort();
}

const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function act(disk: Disk, engine: SyncEngine | null, name: string, step: number, chance: () => number, ledger: Ledger): Promise<string> {
  const { fs } = disk;
  const existing = [...fs.files.keys()].filter((path) => PATHS.includes(path));
  const pick = <T>(items: T[]) => items[Math.floor(chance() * items.length)];
  const roll = chance();

  if (roll < 0.5 || existing.length === 0) {
    const path = pick(PATHS);
    if (path.endsWith(".png"))
      await fs.writeBinary(
        path,
        Uint8Array.from({ length: 64 }, () => Math.floor(chance() * 256)),
      );
    else if (fs.files.has(path) && chance() < 0.7) {
      await fs.writeText(path, `${await fs.readText(path)}${name} adds ${step}.\n`);
      ledger.added.push(`${name} adds ${step}.`);
      engine?.localChanged(path);
      return `${name} adds a line to ${path}`;
    } else {
      const had = fs.files.has(path);
      const deleting = !had && [...disk.store.entries.values()].some((entry) => entry.path === path && entry.hash !== null);
      if (deleting) return `${name} idles, as ${path} is still being deleted`;
      await discard(fs, path, ledger);
      await fs.writeText(path, overwriting(name, step));
      engine?.localChanged(path);
      return `${name} ${had ? "writes over" : "creates"} ${path}`;
    }
    engine?.localChanged(path);
    return `${name} writes ${path}`;
  }

  if (roll < 0.75) {
    const path = pick(existing);
    await discard(fs, path, ledger);
    await fs.remove(path);
    engine?.localDeleted(path);
    return `${name} deletes ${path}`;
  }

  const from = pick(existing);
  const extension = from.slice(from.lastIndexOf("."));
  const to = pick(PATHS.filter((path) => path.endsWith(extension) && !fs.files.has(path)));
  if (!to) return `${name} idles`;
  await fs.rename(from, to);
  engine?.localRenamed(from, to);
  return `${name} renames ${from} to ${to}`;
}

async function settled(devices: Device[]): Promise<string[]> {
  const deadline = Date.now() + 60_000;
  let calm = 0;
  let differing: string[] = [];

  while (Date.now() < deadline) {
    await Promise.all(devices.map((device) => device.engine.idle()));
    const first = contents(devices[0].fs);
    differing = devices.slice(1).flatMap((device) => difference(first, contents(device.fs)));
    const synced = devices.every((device) => device.engine.status === "synced");
    calm = synced && differing.length === 0 ? calm + 1 : 0;
    if (calm >= 4) return [];
    await pause(250);
  }
  return differing.length > 0
    ? differing
    : devices.filter((device) => device.engine.status !== "synced").map((device) => `${device.name} is ${device.engine.status}`);
}

for (const [index, vaultId] of vaultIds.entries()) {
  const seed = Number(process.env.BABELSYNC_SEED ?? 1) + index;

  test(`devices that crash, restart and edit offline end up identical, with every line nobody discarded (seed ${seed})`, async () => {
    const chance = random(seed);
    const faults = random(seed + 7919);
    const history: string[] = [];
    const ledger: Ledger = { added: [], discarded: [] };
    const running = new Map<string, Device>();
    const down = new Map<string, Disk>();
    const everyone: Device[] = [];

    for (const name of NAMES) {
      const device = await boot(name, vaultId, { fs: new MemoryFs(), store: new MemoryStore() }, history, faults);
      running.set(name, device);
      everyone.push(device);
    }

    for (let step = 0; step < steps; step++) {
      const name = NAMES[Math.floor(chance() * NAMES.length)];
      const device = running.get(name);
      const roll = chance();

      if (device && roll < 0.12) {
        down.set(name, crash(device));
        running.delete(name);
        history.push(`${step}: ${name} crashes`);
      } else if (!device && roll < 0.4) {
        history.push(`${step}: ${name} restarts`);
        const back = await boot(name, vaultId, down.get(name)!, history, faults);
        down.delete(name);
        running.set(name, back);
        everyone.push(back);
      } else {
        history.push(`${step}: ` + (await act(device ?? down.get(name)!, device?.engine ?? null, name, step, chance, ledger)));
      }

      await pause(Math.floor(chance() * 40));
    }

    history.push("everyone restarts");
    for (const [name, disk] of down) {
      const back = await boot(name, vaultId, disk, history, faults);
      running.set(name, back);
      everyone.push(back);
    }
    const witness = await boot("witness", vaultId, { fs: new MemoryFs(), store: new MemoryStore() });
    const devices = [...running.values(), witness];

    const differing = await settled(devices);
    const report = () =>
      [
        `seed ${seed}`,
        ...history,
        ...devices.map((device) => `${device.name}: ${[...device.fs.files.keys()].sort().join(", ")}`),
        ...devices.map((device) => `${device.name} errors: ${device.errors.join("; ") || "none"}`),
        ...differing.flatMap((path) =>
          devices.map((device) => {
            const file = device.fs.files.get(path);
            const known = [...device.store.entries.values()].filter((entry) => entry.path === path);
            return `${path} on ${device.name}: ${file ? JSON.stringify(Buffer.from(file.data).toString().slice(0, 200)) : "absent"} mtime ${file?.mtime} known as ${JSON.stringify(known.map(({ doc, ...rest }) => rest))}`;
          }),
        ),
        ...devices.map(
          (device) =>
            `${device.name} knows: ${[...device.store.entries.values()]
              .map((entry) => `${entry.path}=${entry.hash?.slice(0, 6)}/${entry.seq}${entry.dirty ? "/dirty" : ""}`)
              .sort()
              .join(", ")}`,
        ),
      ].join("\n");

    assert.deepEqual(differing, [], report());

    const surfaced = everyone.flatMap((device) => device.errors.filter((error) => error.includes(STORE_FAULT)).map((error) => `${device.name}: ${error}`));
    assert.deepEqual(surfaced, [], `trouble saving sync state reached the person\n${report()}`);

    const notes = [...witness.fs.files.keys()].filter((path) => !path.endsWith(".png"));
    const kept = await Promise.all(notes.map(async (path) => ({ path, text: await witness.fs.readText(path) })));
    const everything = added(kept.map((note) => note.text).join("\n"));
    const discarded = added(ledger.discarded.join("\n"));
    const lost = ledger.added.filter((line) => !everything.includes(line) && !discarded.includes(line));
    const repeated = kept.flatMap(({ path, text }) => ledger.added.filter((line) => occurrences(added(text), line) > 1).map((line) => `${path}: ${line}`));
    const notesNow = kept.map(({ path, text }) => `${path} holds ${JSON.stringify(text)}`).join("\n");
    assert.deepEqual(lost, [], `lines that were added and never deleted or written over are gone\n${report()}\n${notesNow}`);
    assert.deepEqual(repeated, [], `lines appear twice in one note\n${report()}\n${notesNow}`);

    await Promise.all(devices.map((device) => device.engine.stop().then(() => device.client.disconnect())));
  });
}
