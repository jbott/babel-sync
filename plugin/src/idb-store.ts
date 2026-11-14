import type { Batch, LocalEntry, StateStore } from "./fs.ts";

const ENTRIES = "entries";
const META = "meta";

const ATTEMPTS = 3;
const PATIENCE_MS = 15_000;

type Action = (transaction: IDBTransaction) => IDBRequest | void;

export class IdbStore implements StateStore {
  private name: string;
  private database: Promise<IDBDatabase>;
  private closed = false;

  constructor(name: string) {
    this.name = name;
    this.database = this.open();
  }

  private open(): Promise<IDBDatabase> {
    const opening = new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open(this.name, 1);
      request.onupgradeneeded = () => {
        request.result.createObjectStore(ENTRIES, { keyPath: "id" });
        request.result.createObjectStore(META);
      };
      request.onsuccess = () => {
        request.result.onclose = () => this.replace(opening);
        resolve(request.result);
      };
      request.onerror = () => reject(request.error);
      request.onblocked = () => reject(new Error("the sync state database is blocked"));
    });
    return opening;
  }

  private replace(lost: Promise<IDBDatabase>): void {
    if (this.closed || this.database !== lost) return;
    this.database = this.open();
    void lost.then((database) => database.close()).catch(() => {});
  }

  async load(): Promise<{ seq: number; entries: LocalEntry[] }> {
    const entries = await this.request<LocalEntry[]>([ENTRIES], "readonly", (transaction) => transaction.objectStore(ENTRIES).getAll());
    const seq = await this.request<number | undefined>([META], "readonly", (transaction) => transaction.objectStore(META).get("seq"));
    return { seq: seq ?? 0, entries };
  }

  async commit({ entries, removed, seq }: Batch): Promise<void> {
    await this.request([ENTRIES, META], "readwrite", (transaction) => {
      const held = transaction.objectStore(ENTRIES);
      for (const id of removed) held.delete(id);
      for (const entry of entries) held.put({ ...entry });
      if (seq !== undefined) transaction.objectStore(META).put(seq, "seq");
    });
  }

  async probe(): Promise<void> {
    await this.request([META], "readonly", (transaction) => transaction.objectStore(META).get("seq")).catch(() => {});
  }

  async clear(): Promise<void> {
    await this.request([ENTRIES, META], "readwrite", (transaction) => {
      transaction.objectStore(ENTRIES).clear();
      transaction.objectStore(META).clear();
    });
  }

  async close(): Promise<void> {
    this.closed = true;
    await this.database.then((database) => database.close()).catch(() => {});
  }

  private async request<T>(names: string[], mode: IDBTransactionMode, action: Action): Promise<T> {
    for (let attempt = 1; ; attempt++) {
      const connection = this.database;
      try {
        return await this.once<T>(connection, names, mode, action);
      } catch (error) {
        if (attempt === ATTEMPTS || this.closed) throw error;
        this.replace(connection);
      }
    }
  }

  private async once<T>(connection: Promise<IDBDatabase>, names: string[], mode: IDBTransactionMode, action: Action): Promise<T> {
    const database = await connection;

    return new Promise((resolve, reject) => {
      const transaction = database.transaction(names, mode);
      const request = action(transaction);
      const overdue = setTimeout(() => {
        try {
          transaction.abort();
        } catch {
          reject(new Error("the sync state database did not answer"));
        }
      }, PATIENCE_MS);
      const failed = (error: unknown) => {
        clearTimeout(overdue);
        reject(error ?? new Error("the sync state database did not answer"));
      };
      transaction.oncomplete = () => {
        clearTimeout(overdue);
        resolve(request?.result as T);
      };
      transaction.onabort = () => failed(transaction.error ?? request?.error);
      transaction.onerror = () => failed(transaction.error ?? request?.error);
    });
  }
}
