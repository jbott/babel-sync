import assert from "node:assert/strict";
import { test } from "node:test";
import { BabelSyncClient } from "@babelsync/core";
import { SyncEngine } from "../src/engine.ts";
import { MemoryFs, MemoryStore } from "../src/fs.ts";

const baseUrl = process.env.BABELSYNC_URL!;
const token = process.env.BABELSYNC_TOKEN!;
const vaultIds = process.env.BABELSYNC_VAULT_IDS!.split(",");
const steps = Number(process.env.BABELSYNC_STEPS ?? 70);

const NAMES = ["laptop", "phone", "tablet"];
const PATHS = [
  "inbox.md",
  "todo.md",
  "Daily/monday.md",
  "Daily/tuesday.md",
  "Places/cafe.md",
  "Places/park.md",
  "Places/list.base",
  "Attachments/photo.png",
];

type Disk = { fs: MemoryFs; store: MemoryStore };
type Device = Disk & { name: string; client: BabelSyncClient; engine: SyncEngine; errors: string[]; log: string[] };

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

async function boot(name: string, vaultId: string, disk: Disk): Promise<Device> {
  const client = new BabelSyncClient({ baseUrl, token: () => token, transport: WebSocket });
  const errors: string[] = [];
  const engine = new SyncEngine({
    client,
    vaultId,
    fs: disk.fs,
    store: disk.store,
    device: name,
    sessionIdleMs: 50,
    settleMs: 50,
    retryMs: 200,
  });
  const log: string[] = [];
  engine.on("error", (message) => errors.push(message));
  engine.on("log", (line) => log.push(line));
  client.connect();
  await engine.start();
  return { name, ...disk, client, engine, errors, log };
}

function crash(device: Device): Disk {
  const disk = copyOf(device);
  void device.client.disconnect();
  void device.engine.stop().catch(() => {});
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

async function act(disk: Disk, engine: SyncEngine | null, name: string, step: number, chance: () => number): Promise<string> {
  const { fs } = disk;
  const existing = [...fs.files.keys()].filter((path) => PATHS.includes(path));
  const pick = <T>(items: T[]) => items[Math.floor(chance() * items.length)];
  const roll = chance();

  if (roll < 0.5 || existing.length === 0) {
    const path = pick(PATHS);
    if (path.endsWith(".png")) await fs.writeBinary(path, Uint8Array.from({ length: 64 }, () => Math.floor(chance() * 256)));
    else if (fs.files.has(path) && chance() < 0.7) await fs.writeText(path, `${await fs.readText(path)}${name} adds ${step}\n`);
    else await fs.writeText(path, `${name} wrote ${step}\n`);
    engine?.localChanged(path);
    return `${name} writes ${path}`;
  }

  if (roll < 0.75) {
    const path = pick(existing);
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
  return differing.length > 0 ? differing : devices.filter((device) => device.engine.status !== "synced").map((device) => `${device.name} is ${device.engine.status}`);
}

for (const [index, vaultId] of vaultIds.entries()) {
  const seed = Number(process.env.BABELSYNC_SEED ?? 1) + index;

  test(`devices that crash, restart and edit offline still end up identical (seed ${seed})`, async () => {
    const chance = random(seed);
    const history: string[] = [];
    const running = new Map<string, Device>();
    const down = new Map<string, Disk>();
    const everyone: Device[] = [];

    for (const name of NAMES) {
      const device = await boot(name, vaultId, { fs: new MemoryFs(), store: new MemoryStore() });
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
        history.push(`${name} crashes`);
      } else if (!device && roll < 0.4) {
        const back = await boot(name, vaultId, down.get(name)!);
        down.delete(name);
        running.set(name, back);
        everyone.push(back);
        history.push(`${name} restarts`);
      } else {
        history.push(await act(device ?? down.get(name)!, device?.engine ?? null, name, step, chance));
      }

      await pause(Math.floor(chance() * 40));
    }

    for (const [name, disk] of down) {
      const back = await boot(name, vaultId, disk);
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
        ...everyone.flatMap((device) => device.log.map((line) => `${device.name} log: ${line}`)),
        ...differing.flatMap((path) =>
          devices.map((device) => {
            const file = device.fs.files.get(path);
            const known = [...device.store.entries.values()].filter((entry) => entry.path === path);
            return `${path} on ${device.name}: ${file ? JSON.stringify(Buffer.from(file.data).toString().slice(0, 200)) : "absent"} mtime ${file?.mtime} known as ${JSON.stringify(known.map(({ doc, ...rest }) => rest))}`;
          }),
        ),
        ...devices.map((device) => `${device.name} knows: ${[...device.store.entries.values()].map((entry) => `${entry.path}=${entry.hash?.slice(0, 6)}/${entry.seq}${entry.dirty ? "/dirty" : ""}`).sort().join(", ")}`),
      ].join("\n");

    assert.deepEqual(differing, [], report());
    assert.deepEqual(devices.flatMap((device) => device.errors), [], report());

    await Promise.all(devices.map((device) => device.engine.stop().then(() => device.client.disconnect())));
  });
}
