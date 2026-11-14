import assert from "node:assert/strict";
import { test } from "node:test";
import type { LocalEntry } from "../src/fs.ts";
import { IdbStore } from "../src/idb-store.ts";

type Handler = (() => void) | null;

class FakeRequest {
  result: unknown;
  error: Error | null = null;
  onsuccess: Handler = null;
  onerror: Handler = null;
  onblocked: Handler = null;
  onupgradeneeded: Handler = null;
}

class FakeDatabase {
  closing = false;
  onclose: Handler = null;
  private rows: Map<string, Map<unknown, unknown>>;

  constructor(rows: Map<string, Map<unknown, unknown>>) {
    this.rows = rows;
  }

  createObjectStore(name: string): void {
    this.rows.set(name, new Map());
  }

  close(): void {
    this.closing = true;
  }

  transaction(name: string): unknown {
    if (this.closing) throw new Error("The database connection is closing.");
    const rows = this.rows.get(name)!;
    const request = new FakeRequest();
    const transaction = { oncomplete: null as Handler, onabort: null as Handler, onerror: null as Handler, error: null };
    const settle = (result: unknown) => {
      request.result = result;
      setTimeout(() => transaction.oncomplete?.(), 0);
      return request;
    };
    const objectStore = () => ({
      put: (value: { id?: string }, key?: unknown) => settle(rows.set(key ?? value.id, value)),
      delete: (key: unknown) => settle(rows.delete(key)),
      get: (key: unknown) => settle(rows.get(key)),
      getAll: () => settle([...rows.values()]),
      clear: () => settle(rows.clear()),
    });
    return Object.assign(transaction, { objectStore });
  }
}

function fakeIndexedDb(): { opened: FakeDatabase[] } {
  const rows = new Map<string, Map<unknown, unknown>>();
  const opened: FakeDatabase[] = [];
  const open = () => {
    const request = new FakeRequest();
    const database = new FakeDatabase(rows);
    setTimeout(() => {
      request.result = database;
      if (opened.length === 0) request.onupgradeneeded?.();
      opened.push(database);
      request.onsuccess?.();
    }, 0);
    return request;
  };
  Object.assign(globalThis, { indexedDB: { open } });
  return { opened };
}

function entry(n: number): LocalEntry {
  return { id: `id-${n}`, path: `note-${n}.md`, kind: "doc", hash: null, size: 0, mtime: 0, dirty: false, moved: false };
}

test("many writes that meet a lost connection share one new connection", async () => {
  const { opened } = fakeIndexedDb();
  const store = new IdbStore("lost");
  await store.setSeq(1);

  opened[0].closing = true;
  await Promise.all(Array.from({ length: 40 }, (_unused, n) => store.put(entry(n))));

  assert.equal(opened.length, 2);
  assert.equal((await store.load()).entries.length, 40);
  await store.close();
});

test("a connection the system closes is replaced before the next write", async () => {
  const { opened } = fakeIndexedDb();
  const store = new IdbStore("closed");
  await store.setSeq(7);

  opened[0].closing = true;
  opened[0].onclose?.();
  await store.put(entry(1));

  assert.equal(opened.length, 2);
  assert.deepEqual(await store.load(), { seq: 7, entries: [entry(1)] });
  await store.close();
});

test("a store that was closed on purpose does not come back", async () => {
  const { opened } = fakeIndexedDb();
  const store = new IdbStore("stopped");
  await store.setSeq(1);
  await store.close();

  await assert.rejects(store.put(entry(1)), /closing/);
  assert.equal(opened.length, 1);
});
