import assert from "node:assert/strict";
import { after, test } from "node:test";
import { BabelSyncClient } from "@babelsync/core";
import { SyncEngine } from "../src/engine.ts";
import { MemoryFs, MemoryStore } from "../src/fs.ts";

const baseUrl = process.env.BABELSYNC_URL!;
const token = process.env.BABELSYNC_TOKEN!;
const vaultIds = process.env.BABELSYNC_VAULT_IDS!.split(",");

type Device = {
  name: string;
  fs: MemoryFs;
  store: MemoryStore;
  client: BabelSyncClient;
  engine: SyncEngine;
  errors: string[];
};

const devices: Device[] = [];
let nextVault = 0;

function freshVault(): string {
  return vaultIds[nextVault++];
}

async function boot(
  name: string,
  vaultId: string,
  previous?: Pick<Device, "fs" | "store">,
  options: { maxBlobBytes?: number; sessionIdleMs?: number } = {},
): Promise<Device> {
  const fs = previous?.fs ?? new MemoryFs();
  const store = previous?.store ?? new MemoryStore();
  const client = new BabelSyncClient({ baseUrl, token: () => token, transport: WebSocket });
  const errors: string[] = [];
  const engine = new SyncEngine({
    client,
    vaultId,
    fs,
    store,
    device: name,
    sessionIdleMs: 50,
    now: () => new Date("2026-11-10T12:00:00Z"),
    ignore: (path) => path.startsWith(".trash/"),
    ...options,
  });
  engine.on("error", (message) => errors.push(message));
  client.connect();
  await engine.start();

  const device = { name, fs, store, client, engine, errors };
  devices.push(device);
  await eventually(() => engine.status === "synced", `${name} to finish its first sync`);
  return device;
}

async function shutdown(device: Device): Promise<void> {
  await device.engine.stop();
  await device.client.disconnect();
}

async function eventually(check: () => boolean | Promise<boolean>, what: string | (() => string)): Promise<void> {
  const deadline = Date.now() + 20000;
  while (!(await check())) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${typeof what === "string" ? what : what()}`);
    await new Promise((resolve) => setTimeout(resolve, 15));
  }
}

async function text(device: Device, path: string): Promise<string | null> {
  return (await device.fs.stat(path)) ? device.fs.readText(path) : null;
}

function paths(device: Device): string[] {
  return [...device.fs.files.keys()].sort();
}

async function edit(device: Device, path: string, content: string): Promise<void> {
  await device.fs.writeText(path, content);
  device.engine.localChanged(path);
}

after(async () => {
  await Promise.all(devices.map(shutdown));
});

test("files created on one device appear on the other, text and binary", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);

  await edit(laptop, "Daily/today.md", "# Today 😀\r\n- wake up\r\n");
  const image = crypto.getRandomValues(new Uint8Array(4096));
  await laptop.fs.writeBinary("Attachments/pic.png", image);
  laptop.engine.localChanged("Attachments/pic.png");

  await eventually(async () => (await text(phone, "Daily/today.md")) === "# Today 😀\n- wake up\n", "the note");
  await eventually(async () => (await phone.fs.stat("Attachments/pic.png")) !== null, "the image");
  assert.deepEqual(await phone.fs.readBinary("Attachments/pic.png"), image);
  assert.deepEqual(laptop.errors.concat(phone.errors), []);
});

test("edits to the same closed note on two devices are merged, not overwritten", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await edit(laptop, "list.md", "milk\neggs\n");
  await eventually(async () => (await text(phone, "list.md")) === "milk\neggs\n", "the list on the phone");

  await shutdown(phone);
  await phone.fs.writeText("list.md", "milk\neggs\nbread\n");
  await edit(laptop, "list.md", "oat milk\neggs\n");
  await laptop.engine.idle();

  const back = await boot("phone", vault, phone);

  await eventually(async () => (await text(laptop, "list.md")) === "oat milk\neggs\nbread\n", "the merge on the laptop");
  assert.equal(await text(back, "list.md"), "oat milk\neggs\nbread\n");
});

test("typing in an open note reaches a device that has it open, live", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await edit(laptop, "live.md", "start\n");
  await eventually(async () => (await text(phone, "live.md")) === "start\n", "the note on the phone");

  const onLaptop = (await laptop.engine.openDoc("live.md"))!;
  const onPhone = (await phone.engine.openDoc("live.md"))!;
  assert.equal(onLaptop.text.toString(), "start\n");

  onLaptop.text.insert(onLaptop.text.length, "typed on laptop\n");
  onPhone.text.insert(0, "typed on phone\n");

  const merged = "typed on phone\nstart\ntyped on laptop\n";
  await eventually(() => onLaptop.text.toString() === merged && onPhone.text.toString() === merged, "live merge");

  onPhone.awareness.setLocalStateField("user", { name: "phone" });
  await eventually(
    () => [...onLaptop.awareness.getStates().values()].some((state: any) => state.user?.name === "phone"),
    "the phone's cursor on the laptop",
  );

  onLaptop.release();
  onPhone.release();
  await eventually(async () => (await text(laptop, "live.md")) === merged, "the laptop file after closing");
  await eventually(async () => (await text(phone, "live.md")) === merged, "the phone file after closing");
});

test("renames and deletions follow, and a note keeps its identity when moved", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await edit(laptop, "draft.md", "v1\n");
  await edit(laptop, "junk.md", "x\n");
  await eventually(() => paths(phone).length === 2, "both notes on the phone");

  await laptop.fs.rename("draft.md", "Final/done.md");
  laptop.engine.localRenamed("draft.md", "Final/done.md");
  await laptop.fs.remove("junk.md");
  laptop.engine.localDeleted("junk.md");

  await eventually(
    () => paths(phone).join() === "Final/done.md",
    () => `the phone to follow, it has ${paths(phone).join()} and the laptop ${paths(laptop).join()}; errors ${[...phone.errors, ...laptop.errors].join()}`,
  );

  await edit(phone, "Final/done.md", "v1\nv2\n");
  await eventually(async () => (await text(laptop, "Final/done.md")) === "v1\nv2\n", "an edit after the move");
});

test("a folder deleted or renamed on one device goes, with nothing left behind, on the other", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await edit(laptop, "Trip/Days/one.md", "one\n");
  await edit(laptop, "Trip/Days/two.md", "two\n");
  await edit(laptop, "Trip/plan.md", "plan\n");
  await edit(laptop, "keep.md", "keep\n");
  await eventually(() => paths(phone).length === 4, "all four notes on the phone");

  for (const path of ["Trip/Days/one.md", "Trip/Days/two.md"]) await laptop.fs.rename(path, path.replace("Trip/Days", "Trip/Log"));
  laptop.engine.localFolderRenamed("Trip/Days", "Trip/Log");
  await eventually(
    () => paths(phone).join() === "Trip/Log/one.md,Trip/Log/two.md,Trip/plan.md,keep.md" && !phone.fs.folders.has("Trip/Days"),
    () => `the phone to follow the folder rename, it has ${paths(phone).join()} in ${[...phone.fs.folders].join()}`,
  );

  for (const path of paths(laptop).filter((path) => path.startsWith("Trip/"))) await laptop.fs.remove(path);
  laptop.engine.localFolderDeleted("Trip");
  await eventually(
    () => paths(phone).join() === "keep.md" && phone.fs.folders.size === 0,
    () => `the phone to drop the folder, it has ${paths(phone).join()} in ${[...phone.fs.folders].join()}`,
  );
});

test("changes made while a device was off are caught up on return", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await edit(laptop, "keep.md", "keep\n");
  await edit(laptop, "remove.md", "remove\n");
  await edit(laptop, "move.md", "move\n");
  await eventually(() => paths(phone).length === 3, "three notes on the phone");
  await shutdown(phone);

  await phone.fs.writeText("offline-new.md", "written on a plane\n");
  await phone.fs.remove("remove.md");
  await phone.fs.writeText("keep.md", "keep\nphone addition\n");
  await laptop.fs.rename("move.md", "moved.md");
  laptop.engine.localRenamed("move.md", "moved.md");
  await edit(laptop, "laptop-new.md", "meanwhile\n");
  await laptop.engine.idle();

  const back = await boot("phone", vault, phone);
  const expected = ["keep.md", "laptop-new.md", "moved.md", "offline-new.md"];

  await eventually(() => paths(laptop).join() === expected.join(), "the laptop to match");
  assert.deepEqual(paths(back), expected);
  assert.equal(await text(laptop, "keep.md"), "keep\nphone addition\n");
  assert.equal(await text(laptop, "offline-new.md"), "written on a plane\n");
});

test("the same new path with different content on two devices keeps both", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  await edit(laptop, "ideas.md", "laptop idea\n");
  await laptop.engine.idle();

  const fs = new MemoryFs();
  await fs.writeText("ideas.md", "phone idea\n");
  const phone = await boot("phone", vault, { fs, store: new MemoryStore() });
  const copy = "ideas (conflict phone 2026-11-10 120000).md";

  await eventually(() => paths(laptop).join() === [copy, "ideas.md"].sort().join(), "the conflict copy on the laptop");
  assert.equal(await text(phone, "ideas.md"), "laptop idea\n");
  assert.equal(await text(phone, copy), "phone idea\n");
  assert.equal(await text(laptop, copy), "phone idea\n");
});

test("the same new path with identical content is simply adopted", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  await edit(laptop, "same.md", "identical\n");
  await laptop.engine.idle();

  const fs = new MemoryFs();
  await fs.writeText("same.md", "identical\n");
  const phone = await boot("phone", vault, { fs, store: new MemoryStore() });

  assert.deepEqual(paths(phone), ["same.md"]);
  assert.deepEqual(paths(laptop), ["same.md"]);
});

test("an attachment replaced on two devices keeps both versions", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await laptop.fs.writeBinary("logo.png", new Uint8Array([1, 1, 1]));
  laptop.engine.localChanged("logo.png");
  await eventually(async () => (await phone.fs.stat("logo.png")) !== null, "the logo on the phone");
  await shutdown(phone);

  await phone.fs.writeBinary("logo.png", new Uint8Array([3, 3, 3]));
  await laptop.fs.writeBinary("logo.png", new Uint8Array([2, 2, 2]));
  laptop.engine.localChanged("logo.png");
  await laptop.engine.idle();

  const back = await boot("phone", vault, phone);
  const copy = "logo (conflict phone 2026-11-10 120000).png";

  await eventually(async () => (await laptop.fs.stat(copy)) !== null, "the conflict copy on the laptop");
  assert.deepEqual(await back.fs.readBinary("logo.png"), new Uint8Array([2, 2, 2]));
  assert.deepEqual(await laptop.fs.readBinary(copy), new Uint8Array([3, 3, 3]));
});

test("attachments over the device's size limit are skipped without being deleted", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  await laptop.fs.writeBinary("video.mp4", new Uint8Array(5000));
  laptop.engine.localChanged("video.mp4");
  await edit(laptop, "small.md", "ok\n");
  await laptop.engine.idle();

  const phone = await boot("phone", vault, undefined, { maxBlobBytes: 1000 });
  await shutdown(phone);
  await boot("phone", vault, phone, { maxBlobBytes: 1000 });
  await new Promise((resolve) => setTimeout(resolve, 200));

  assert.deepEqual(paths(phone), ["small.md"]);
  assert.deepEqual(paths(laptop), ["small.md", "video.mp4"]);
});

test("hundreds of notes created at once all arrive", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault, undefined, { sessionIdleMs: 30_000 });
  const phone = await boot("phone", vault, undefined, { sessionIdleMs: 30_000 });

  for (let n = 0; n < 250; n++) await edit(laptop, `Import/note ${n}.md`, `note ${n}\n`);

  await eventually(
    () => paths(phone).length === 250,
    () => `the phone to have all 250, it has ${paths(phone).length}; errors ${[...new Set([...phone.errors, ...laptop.errors])].join()}`,
  );
  assert.deepEqual([...laptop.errors, ...phone.errors], []);
  assert.equal(await text(phone, "Import/note 249.md"), "note 249\n");
});

test("ignored paths never leave the device", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);

  await edit(laptop, ".trash/old.md", "gone\n");
  await edit(laptop, "real.md", "here\n");

  await eventually(async () => (await text(phone, "real.md")) === "here\n", "the real note");
  assert.deepEqual(paths(phone), ["real.md"]);
});
