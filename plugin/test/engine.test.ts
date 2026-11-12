import assert from "node:assert/strict";
import { after, test } from "node:test";
import { BabelSyncClient } from "@babelsync/core";
import { SyncEngine } from "../src/engine.ts";
import { MemoryFs, MemoryStore } from "../src/fs.ts";
import { conflictPath } from "../src/text.ts";

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

function watch(fs: MemoryFs, engine: SyncEngine): void {
  fs.watcher = (event) => {
    if (event.type === "changed") engine.localChanged(event.path);
    else if (event.type === "deleted") engine.localDeleted(event.path);
    else if (event.type === "folderCreated") engine.localFolderCreated(event.path);
    else if (event.type === "renamed") engine.localRenamed(event.from, event.path);
  };
}

async function boot(
  name: string,
  vaultId: string,
  previous?: Pick<Device, "fs" | "store">,
  options: { maxBlobBytes?: number; sessionIdleMs?: number; retryMs?: number; ignore?: (path: string) => boolean } = {},
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
    settleMs: 50,
    now: () => new Date("2026-11-10T12:00:00Z"),
    ignore: (path) => path.startsWith(".trash/"),
    ...options,
  });
  engine.on("error", (message) => errors.push(message));
  watch(fs, engine);
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

async function eventually(check: () => boolean | Promise<boolean>, what: string | (() => string | Promise<string>)): Promise<void> {
  const deadline = Date.now() + 20000;
  while (!(await check())) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${typeof what === "string" ? what : await what()}`);
    await new Promise((resolve) => setTimeout(resolve, 15));
  }
}

async function savedPlace(device: Device): Promise<number> {
  let seen = -1;
  let since = Date.now();
  await eventually(() => {
    if (device.store.seq !== seen) {
      seen = device.store.seq;
      since = Date.now();
    }
    return seen > 0 && Date.now() - since > 250;
  }, `${device.name} to save its place in the feed`);
  return seen;
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
  laptop.fs.folders.delete("Trip/Days");
  laptop.engine.localFolderRenamed("Trip/Days", "Trip/Log");
  await eventually(
    () => paths(phone).join() === "Trip/Log/one.md,Trip/Log/two.md,Trip/plan.md,keep.md" && !phone.fs.folders.has("Trip/Days"),
    () => `the phone to follow the folder rename, it has ${paths(phone).join()} in ${[...phone.fs.folders].join()}`,
  );

  for (const path of paths(laptop).filter((path) => path.startsWith("Trip/"))) await laptop.fs.remove(path);
  laptop.fs.folders.clear();
  laptop.engine.localFolderDeleted("Trip");
  await eventually(
    () => paths(phone).join() === "keep.md" && phone.fs.folders.size === 0,
    () => `the phone to drop the folder, it has ${paths(phone).join()} in ${[...phone.fs.folders].join()}`,
  );
});

test("an empty folder someone made is kept everywhere, and one nobody made is cleared away", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  await edit(laptop, "Old/note.md", "note\n");
  await laptop.fs.makeFolder("Inbox");
  laptop.engine.localFolderCreated("Inbox");

  const fs = new MemoryFs();
  await fs.makeFolder("Leftover/From before");
  const phone = await boot("phone", vault, { fs, store: new MemoryStore() });
  await eventually(
    () => [...phone.fs.folders].sort().join() === "Inbox,Old" && paths(phone).join() === "Old/note.md",
    () => `the phone to have the made folder and not the leftover, it has ${[...phone.fs.folders].sort().join()}`,
  );

  await laptop.fs.rename("Old/note.md", "note.md");
  laptop.engine.localRenamed("Old/note.md", "note.md");
  await eventually(() => paths(phone).join() === "note.md", "the note to move on the phone");
  await eventually(
    () => [...phone.fs.folders].sort().join() === "Inbox,Old",
    () => `a folder emptied by hand to still be a folder, the phone has ${[...phone.fs.folders].sort().join()}`,
  );

  phone.fs.folders.delete("Inbox");
  phone.fs.folders.add("Box");
  phone.engine.localFolderRenamed("Inbox", "Box");
  await eventually(() => [...laptop.fs.folders].sort().join() === "Box,Old", () => `the laptop to follow the rename, it has ${[...laptop.fs.folders].join()}`);

  for (const folder of ["Box", "Old"]) {
    laptop.fs.folders.delete(folder);
    laptop.engine.localFolderDeleted(folder);
  }
  await eventually(() => phone.fs.folders.size === 0, () => `the deleted folders to go, the phone has ${[...phone.fs.folders].join()}`);
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

test("an older version of an attachment on a device with no sync history is replaced, not kept as a conflict", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  await laptop.fs.writeBinary("logo.png", new Uint8Array([1, 1, 1]));
  laptop.engine.localChanged("logo.png");
  await laptop.engine.idle();
  await laptop.fs.writeBinary("logo.png", new Uint8Array([2, 2, 2]));
  laptop.engine.localChanged("logo.png");
  await laptop.engine.idle();

  const fs = new MemoryFs();
  await fs.writeBinary("logo.png", new Uint8Array([1, 1, 1]));
  const phone = await boot("phone", vault, { fs, store: new MemoryStore() });

  assert.deepEqual(await phone.fs.readBinary("logo.png"), new Uint8Array([2, 2, 2]));
  assert.deepEqual(paths(phone), ["logo.png"]);
  assert.deepEqual(paths(laptop), ["logo.png"]);
});

test("a note renamed over one that was deleted while the device was off replaces it everywhere", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await edit(laptop, "old.md", "old\n");
  await edit(laptop, "draft.md", "draft\n");
  await eventually(async () => (await text(phone, "draft.md")) === "draft\n", "both notes on the phone");
  await shutdown(phone);

  await phone.fs.remove("old.md");
  await phone.fs.rename("draft.md", "old.md");
  const back = await boot("phone", vault, phone);

  await eventually(() => paths(laptop).join() === "old.md", () => `the laptop to hold only old.md, it has ${paths(laptop).join()}`);
  assert.equal(await text(laptop, "old.md"), "draft\n");
  assert.deepEqual(paths(back), ["old.md"]);
});

test("an attachment moved into a new folder stays one file, and a conflict copy never grows a second suffix", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await phone.fs.writeBinary("Pasted image.jpg", new Uint8Array([7, 7, 7]));
  phone.engine.localChanged("Pasted image.jpg");
  await eventually(async () => (await laptop.fs.stat("Pasted image.jpg")) !== null, "the image on the laptop");

  await phone.fs.makeFolder("Attachments");
  phone.engine.localFolderCreated("Attachments");
  await phone.fs.rename("Pasted image.jpg", "Attachments/Pasted image.jpg");
  phone.engine.localRenamed("Pasted image.jpg", "Attachments/Pasted image.jpg");
  phone.engine.localChanged("Attachments/Pasted image.jpg");
  phone.engine.rescan();

  await eventually(() => paths(laptop).join() === "Attachments/Pasted image.jpg", () => `the laptop to hold only the moved image, it has ${paths(laptop).join()}`);
  await eventually(() => phone.engine.status === "synced", "the phone to settle");
  assert.deepEqual(paths(phone), ["Attachments/Pasted image.jpg"]);

  const once = conflictPath("Attachments/Pasted image.jpg", "Phone", new Date("2026-11-11T20:31:01Z"));
  assert.equal(once, "Attachments/Pasted image (conflict Phone 2026-11-11 203101).jpg");
  assert.equal(conflictPath(once, "Phone", new Date("2026-11-11T20:32:48Z")), "Attachments/Pasted image (conflict Phone 2026-11-11 203248).jpg");
  assert.equal(conflictPath("a (conflict Phone 2026-11-11 203101) 2.md", "Desk", new Date("2026-11-11T20:32:48Z")), "a (conflict Desk 2026-11-11 203248).md");
  assert.equal(conflictPath("a.md", "John's (work) iPad/2", new Date("2026-11-11T20:32:48Z")), "a (conflict John's work iPad 2 2026-11-11 203248).md");
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

  await shutdown(phone);
  const roomier = await boot("phone", vault, phone);
  await eventually(() => paths(roomier).join() === "small.md,video.mp4", "the video once the limit allows it");
});

test("a note edited offline survives another device deleting it", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await edit(laptop, "plan.md", "first draft\n");
  await eventually(async () => (await text(phone, "plan.md")) === "first draft\n", "the plan on the phone");
  await phone.client.disconnect();
  await eventually(() => phone.engine.status === "offline", "the phone to notice it is offline");

  await phone.fs.writeText("plan.md", "first draft\nwritten on a plane\n");
  await phone.engine.idle();
  await laptop.fs.remove("plan.md");
  await eventually(() => laptop.engine.status === "synced" && paths(laptop).length === 0, "the laptop to delete the plan");

  phone.client.connect();
  await eventually(async () => (await text(laptop, "plan.md")) === "first draft\nwritten on a plane\n", "the offline edit on the laptop");
  assert.equal(await text(phone, "plan.md"), "first draft\nwritten on a plane\n");
});

test("changing only the case of a name is a rename on devices that cannot tell cases apart", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault, { fs: new MemoryFs({ caseBlind: true }), store: new MemoryStore() });
  const phone = await boot("phone", vault, { fs: new MemoryFs({ caseBlind: true }), store: new MemoryStore() });
  await edit(laptop, "readme.md", "hello\n");
  await eventually(() => paths(phone).join() === "readme.md", "the note on the phone");

  await laptop.fs.rename("readme.md", "README.md");
  await eventually(() => paths(phone).join() === "README.md", () => `the phone to follow, it has ${paths(phone).join()}`);
  await eventually(() => laptop.engine.status === "synced" && phone.engine.status === "synced", "both to settle");
  assert.deepEqual(paths(laptop), ["README.md"]);
  assert.equal(await text(phone, "README.md"), "hello\n");

  await phone.fs.writeText("Readme.md", "hello again\n");
  await eventually(async () => (await text(laptop, "README.md")) === "hello again\n", "an edit through another spelling");
  assert.deepEqual(paths(laptop), ["README.md"]);
});

test("a second note whose name differs only by case is kept under another name", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault, { fs: new MemoryFs({ caseBlind: true }), store: new MemoryStore() });
  await edit(laptop, "todo.md", "lower\n");
  await eventually(() => paths(phone).join() === "todo.md", "the first note on the phone");

  await edit(laptop, "TODO.md", "upper\n");
  const copy = "TODO (conflict laptop 2026-11-10 120000).md";
  await eventually(() => paths(phone).join() === [copy, "todo.md"].join(), () => `both notes on the phone, it has ${paths(phone).join()}`);
  assert.equal(await text(phone, "todo.md"), "lower\n");
  assert.equal(await text(phone, copy), "upper\n");
});

test("two notes that swapped names while a device was away swap there too, with no conflict copy", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await edit(laptop, "a.md", "was a\n");
  await edit(laptop, "b.md", "was b\n");
  await eventually(() => paths(phone).join() === "a.md,b.md", "both notes on the phone");
  await shutdown(phone);

  const settled = () => eventually(() => laptop.engine.status === "synced", "the laptop to settle");
  await laptop.fs.rename("a.md", "c.md");
  await settled();
  await laptop.fs.rename("b.md", "a.md");
  await settled();
  await laptop.fs.rename("c.md", "b.md");
  await settled();

  const back = await boot("phone", vault, phone);
  await eventually(async () => (await text(back, "a.md")) === "was b\n" && (await text(back, "b.md")) === "was a\n", "the swap on the phone");
  await eventually(() => back.engine.status === "synced" && laptop.engine.status === "synced", "both to settle");
  assert.deepEqual(paths(back), ["a.md", "b.md"]);
  assert.deepEqual(paths(laptop), ["a.md", "b.md"]);
});

test("deleting a folder does not delete notes in it this device never saw", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await laptop.fs.makeFolder("Projects");
  await eventually(() => phone.fs.folders.has("Projects"), "the folder on the phone");
  await shutdown(phone);

  await edit(laptop, "Projects/idea.md", "do not lose me\n");
  await eventually(() => laptop.engine.status === "synced", "the laptop to send the idea");
  phone.fs.folders.delete("Projects");

  const back = await boot("phone", vault, phone);
  back.engine.localFolderDeleted("Projects");
  await eventually(async () => (await text(back, "Projects/idea.md")) === "do not lose me\n", "the idea on the phone");
  await eventually(() => back.engine.status === "synced" && laptop.engine.status === "synced", "both to settle");
  assert.equal(await text(laptop, "Projects/idea.md"), "do not lose me\n");
});

test("a file this device cannot store is left out without holding up the rest", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  await edit(laptop, "what?.md", "fine on a laptop\n");
  await eventually(() => laptop.engine.status === "synced", "the laptop to send it");

  const fs = new MemoryFs({ refuses: (path) => path.includes("?") });
  const phone = await boot("phone", vault, { fs, store: new MemoryStore() }, { retryMs: 30 });
  await edit(laptop, "after.md", "still arrives\n");
  await eventually(async () => (await text(phone, "after.md")) === "still arrives\n", "a later note on the phone");
  await eventually(() => phone.engine.status === "synced", "the phone to settle");

  assert.deepEqual(paths(phone), ["after.md"]);
  assert.deepEqual(paths(laptop), ["after.md", "what?.md"]);
  assert.ok(phone.errors.some((message) => message.includes("cannot be kept on this device")));
});

test("a note saved by writing a new file over it stays the same note", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await edit(laptop, "essay.md", "one\n");
  await eventually(async () => (await text(phone, "essay.md")) === "one\n", "the essay on the phone");
  const id = () => [...laptop.store.entries.values()].find((entry) => entry.path === "essay.md")?.id;
  const original = id();

  await laptop.fs.writeText("essay.md.tmp", "one\ntwo\n");
  await eventually(() => paths(phone).length === 2, "the temporary file on the phone");
  await laptop.fs.rename("essay.md.tmp", "essay.md");

  await eventually(async () => (await text(phone, "essay.md")) === "one\ntwo\n" && paths(phone).length === 1, () => `the save on the phone, it has ${paths(phone).join()}`);
  await eventually(() => laptop.engine.status === "synced", "the laptop to settle");
  assert.deepEqual(paths(laptop), ["essay.md"]);
  assert.equal(id(), original);
});

test("bases and canvases are text that merges, and a device that held one as an attachment follows", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  await edit(laptop, "Places/Food.base", "views:\n");
  await eventually(() => [...laptop.store.entries.values()].some((entry) => entry.path === "Places/Food.base" && entry.hash !== null), "the base on the server");
  const created = [...laptop.store.entries.values()].find((entry) => entry.path === "Places/Food.base")!;
  assert.equal(created.kind, "doc");

  const fs = new MemoryFs();
  const store = new MemoryStore();
  await fs.writeText("Places/Food.base", "views:\n  - edited before the change\n");
  await store.put({ ...created, kind: "blob", hash: "an-older-attachment", doc: undefined, dirty: false, moved: false });
  const phone = await boot("phone", vault, { fs, store });

  await eventually(
    async () => (await text(phone, "Places/Food.base")) === "views:\n" && paths(phone).length === 2,
    () => `the phone to take the note and keep its own copy, it has ${paths(phone).join()}; errors ${phone.errors.join()}`,
  );
  const kept = paths(phone).find((path) => path.includes("conflict"))!;
  assert.equal(await text(phone, kept), "views:\n  - edited before the change\n");
  await eventually(async () => (await text(laptop, kept)) !== null, "the kept copy on the laptop");

  await edit(phone, "Places/Food.base", "views:\n  - type: table\n");
  await edit(laptop, "Places/Food.base", "filters: none\nviews:\n");
  const merged = "filters: none\nviews:\n  - type: table\n";
  await eventually(
    async () => (await text(laptop, "Places/Food.base")) === merged && (await text(phone, "Places/Food.base")) === merged,
    async () => `both edits in the base, laptop has ${JSON.stringify(await text(laptop, "Places/Food.base"))} and phone ${JSON.stringify(await text(phone, "Places/Food.base"))}`,
  );
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

test("a note the server deleted without this device hearing of it is cleared away, not an error", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await edit(laptop, "old.md", "finished\n");
  await edit(laptop, "kept.md", "draft\n");
  await eventually(async () => (await text(phone, "kept.md")) === "draft\n", "both notes on the phone");

  await shutdown(phone);
  await laptop.fs.remove("old.md");
  laptop.engine.localDeleted("old.md");
  await laptop.fs.remove("kept.md");
  laptop.engine.localDeleted("kept.md");
  await edit(laptop, "later.md", "newer\n");
  await laptop.engine.idle();
  await phone.fs.writeText("kept.md", "draft, with more written offline\n");
  phone.store.seq = laptop.store.seq;

  const back = await boot("phone", vault, phone);
  assert.equal(await back.engine.openDoc("old.md"), null);
  back.engine.localChanged("kept.md");

  await eventually(async () => (await text(back, "old.md")) === null, "the deleted note to leave the phone");
  await eventually(
    async () => (await text(laptop, "kept.md")) === "draft, with more written offline\n",
    "the note edited offline to come back as a new note",
  );
  assert.deepEqual(back.errors, []);
});

test("the saved place in the feed never passes a change that is still waiting to be applied", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await edit(laptop, "first.md", "one\n");
  await eventually(async () => (await text(phone, "first.md")) === "one\n", "the first note");
  const before = await savedPlace(phone);

  let release = () => {};
  const held = new Promise<void>((resolve) => (release = resolve));
  const write = phone.fs.writeText.bind(phone.fs);
  phone.fs.writeText = async (path, content) => {
    await held;
    return write(path, content);
  };

  for (let n = 0; n < 5; n++) await edit(laptop, `burst ${n}.md`, `note ${n}\n`);
  await laptop.engine.idle();
  await new Promise((resolve) => setTimeout(resolve, 400));
  assert.equal(phone.store.seq, before);

  release();
  await eventually(async () => (await text(phone, "burst 4.md")) === "note 4\n", "the burst to land");
  await eventually(() => phone.store.seq > before, "the phone to save its new place");
});

test("a change that fails to apply is asked for again instead of being skipped", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault, undefined, { retryMs: 100 });

  let failures = 1;
  const write = phone.fs.writeText.bind(phone.fs);
  phone.fs.writeText = async (path, content) => {
    if (path === "fragile.md" && failures-- > 0) throw new Error("disk hiccup");
    return write(path, content);
  };

  await edit(laptop, "fragile.md", "first try fails\n");
  await edit(laptop, "sturdy.md", "fine\n");

  await eventually(async () => (await text(phone, "sturdy.md")) === "fine\n", "the note after the failed one");
  await eventually(async () => (await text(phone, "fragile.md")) === "first try fails\n", "the failed note to be fetched again");
  await eventually(() => phone.engine.status === "synced", "the phone to report synced again");
  assert.deepEqual(phone.errors, ["disk hiccup"]);
});

test("a device that skipped changes in the past notices the count is off and fetches what it lacks", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await edit(laptop, "a.md", "a\n");
  await edit(laptop, "b.md", "b\n");
  await eventually(async () => (await text(phone, "b.md")) === "b\n", "both notes on the phone");
  await savedPlace(phone);

  await shutdown(phone);
  const lost = [...phone.store.entries.values()].find((entry) => entry.path === "b.md")!;
  phone.store.entries.delete(lost.id);
  phone.fs.files.delete("b.md");

  const back = await boot("phone", vault, phone);
  await eventually(async () => (await text(back, "b.md")) === "b\n", "the skipped note to arrive");
  assert.equal(await text(laptop, "b.md"), "b\n");
  assert.deepEqual(back.errors, []);
});

test("a path that starts being ignored is left alone on the device and on the server", async () => {
  const vault = freshVault();
  const laptop = await boot("laptop", vault);
  const phone = await boot("phone", vault);
  await edit(laptop, "own/build.md", "first\n");
  await eventually(async () => (await text(phone, "own/build.md")) === "first\n", "the file on the phone");
  await shutdown(phone);

  const back = await boot("phone", vault, phone, { ignore: (path) => path.startsWith("own/") });
  await back.fs.writeText("own/build.md", "the phone's own\n");
  await edit(laptop, "own/build.md", "second\n");
  await edit(laptop, "other.md", "arrives\n");
  await eventually(async () => (await text(back, "other.md")) === "arrives\n", "a later note on the phone");
  await eventually(() => back.engine.status === "synced", "the phone to settle");

  assert.equal(await text(back, "own/build.md"), "the phone's own\n");
  assert.equal(await text(laptop, "own/build.md"), "second\n");
  assert.equal(back.engine.fileCount, 1);
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
