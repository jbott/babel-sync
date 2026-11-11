import type { LocalEntry, StateStore } from "./fs.ts";

const ENTRIES = "entries";
const META = "meta";

export class IdbStore implements StateStore {
  private database: Promise<IDBDatabase>;

  constructor(name: string) {
    this.database = new Promise((resolve, reject) => {
      const request = indexedDB.open(name, 1);
      request.onupgradeneeded = () => {
        request.result.createObjectStore(ENTRIES, { keyPath: "id" });
        request.result.createObjectStore(META);
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  }

  async load(): Promise<{ seq: number; entries: LocalEntry[] }> {
    const entries = await this.request<LocalEntry[]>(ENTRIES, "readonly", (store) => store.getAll());
    const seq = await this.request<number | undefined>(META, "readonly", (store) => store.get("seq"));
    return { seq: seq ?? 0, entries };
  }

  async put(entry: LocalEntry): Promise<void> {
    await this.request(ENTRIES, "readwrite", (store) => store.put({ ...entry }));
  }

  async remove(id: string): Promise<void> {
    await this.request(ENTRIES, "readwrite", (store) => store.delete(id));
  }

  async setSeq(seq: number): Promise<void> {
    await this.request(META, "readwrite", (store) => store.put(seq, "seq"));
  }

  async clear(): Promise<void> {
    await this.request(ENTRIES, "readwrite", (store) => store.clear());
    await this.request(META, "readwrite", (store) => store.clear());
  }

  async close(): Promise<void> {
    (await this.database).close();
  }

  private async request<T>(
    name: string,
    mode: IDBTransactionMode,
    action: (store: IDBObjectStore) => IDBRequest,
  ): Promise<T> {
    const database = await this.database;
    return new Promise((resolve, reject) => {
      const request = action(database.transaction(name, mode).objectStore(name));
      request.onsuccess = () => resolve(request.result as T);
      request.onerror = () => reject(request.error);
    });
  }
}
