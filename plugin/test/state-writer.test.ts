import assert from "node:assert/strict";
import { test } from "node:test";
import { type Batch, type LocalEntry, MemoryStore } from "../src/fs.ts";
import { Abandoned, StateWriter } from "../src/state-writer.ts";

class Outage extends MemoryStore {
  down = false;
  commits: Batch[] = [];

  override async load() {
    if (this.down) throw new Error("no answer");
    return super.load();
  }

  override async commit(batch: Batch) {
    if (this.down) throw new Error("no answer");
    this.commits.push(batch);
    return super.commit(batch);
  }
}

function entry(id: string, path = `${id}.md`): LocalEntry {
  return { id, path, kind: "doc", hash: null, size: 0, mtime: 0, dirty: false, moved: false };
}

const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

test("writes made while the store is away are saved together, in order, once it is back", async () => {
  const store = new Outage();
  const heard: Array<string | null> = [];
  const writer = new StateWriter(store, (trouble) => heard.push(trouble), 5);

  store.down = true;
  const saved = [writer.put(entry("a")), writer.put(entry("b")), writer.remove("a"), writer.put(entry("b", "moved.md")), writer.setSeq(9)];
  await pause(40);
  assert.deepEqual(heard, ["no answer"]);
  assert.equal(store.entries.size, 0);

  store.down = false;
  await Promise.all(saved);
  assert.deepEqual(heard, ["no answer", null]);
  assert.deepEqual([...store.entries.values()], [entry("b", "moved.md")]);
  assert.equal(store.seq, 9);
  assert.ok(store.commits.length <= 2);
});

test("a note removed and written again is kept", async () => {
  const store = new Outage();
  const writer = new StateWriter(store, () => {}, 5);

  await Promise.all([writer.put(entry("a")), writer.remove("a"), writer.put(entry("a", "back.md"))]);
  assert.deepEqual([...store.entries.values()], [entry("a", "back.md")]);
});

test("loading waits for the store instead of failing", async () => {
  const store = new Outage();
  await store.commit({ entries: [entry("a")], removed: [], seq: 3 });
  const writer = new StateWriter(store, () => {}, 5);

  store.down = true;
  const loading = writer.load();
  await pause(30);
  store.down = false;
  assert.deepEqual(await loading, { seq: 3, entries: [entry("a")] });
});

test("closing gives up what was waiting, and waking retries at once", async () => {
  const store = new Outage();
  const writer = new StateWriter(store, () => {}, 60_000);

  store.down = true;
  const first = writer.put(entry("a"));
  await pause(10);
  store.down = false;
  writer.retry();
  await first;

  store.down = true;
  const second = writer.put(entry("b"));
  await pause(10);
  writer.close();
  await assert.rejects(second, Abandoned);
  await assert.rejects(writer.put(entry("c")), Abandoned);
  assert.deepEqual([...store.entries.keys()], ["a"]);
});
