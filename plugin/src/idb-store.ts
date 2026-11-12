import type { LocalEntry, StateStore } from "./fs.ts";

const ENTRIES = "entries";
const META = "meta";

const ATTEMPTS = 3;

export class IdbStore implements StateStore {
  private name: string;
  private database: Promise<IDBDatabase>;
  private closed = false;

  constructor(name: string) {
    this.name = name;
    this.database = this.open();
  }

  private open(): Promise<IDBDatabase> {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open(this.name, 1);
      request.onupgradeneeded = () => {
        request.result.createObjectStore(ENTRIES, { keyPath: "id" });
        request.result.createObjectStore(META);
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
      request.onblocked = () => reject(new Error("the sync state database is blocked"));
    });
  }

  private reopen(): void {
    if (this.closed) return;
    const stale = this.database;
    this.database = this.open();
    void stale.then((database) => database.close()).catch(() => {});
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
    this.closed = true;
    await this.database.then((database) => database.close()).catch(() => {});
  }

  private async request<T>(name: string, mode: IDBTransactionMode, action: (store: IDBObjectStore) => IDBRequest): Promise<T> {
    for (let attempt = 1; ; attempt++) {
      try {
        return await this.once<T>(name, mode, action);
      } catch (error) {
        if (attempt === ATTEMPTS || this.closed) throw error;
        this.reopen();
      }
    }
  }

  private async once<T>(name: string, mode: IDBTransactionMode, action: (store: IDBObjectStore) => IDBRequest): Promise<T> {
    const database = await this.database;

    return new Promise((resolve, reject) => {
      const transaction = database.transaction(name, mode);
      const request = action(transaction.objectStore(name));
      transaction.oncomplete = () => resolve(request.result as T);
      transaction.onabort = () => reject(transaction.error ?? request.error ?? new Error("the sync state write was aborted"));
      transaction.onerror = () => reject(transaction.error ?? request.error);
    });
  }
}
