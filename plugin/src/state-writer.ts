import type { Batch, LocalEntry, StateStore } from "./fs.ts";

const FIRST_RETRY_MS = 250;
const LONGEST_RETRY_MS = 5_000;

export class Abandoned extends Error {
  constructor() {
    super("the sync state was closed");
  }
}

type Waiter = { resolve: () => void; reject: (error: unknown) => void };

export class StateWriter {
  private store: StateStore;
  private onTrouble: (trouble: string | null) => void;
  private retryMs: number;
  private entries = new Map<string, LocalEntry>();
  private removed = new Set<string>();
  private seq: number | undefined;
  private waiters: Waiter[] = [];
  private writing = false;
  private closed = false;
  private troubled = false;
  private wake: (() => void) | null = null;

  constructor(store: StateStore, onTrouble: (trouble: string | null) => void, retryMs = FIRST_RETRY_MS) {
    this.store = store;
    this.onTrouble = onTrouble;
    this.retryMs = retryMs;
  }

  load(): Promise<{ seq: number; entries: LocalEntry[] }> {
    return this.patiently(() => this.store.load());
  }

  put(entry: LocalEntry): Promise<void> {
    this.removed.delete(entry.id);
    this.entries.set(entry.id, { ...entry });
    return this.saved();
  }

  remove(id: string): Promise<void> {
    this.entries.delete(id);
    this.removed.add(id);
    return this.saved();
  }

  setSeq(seq: number): Promise<void> {
    this.seq = seq;
    return this.saved();
  }

  retry(): void {
    this.wake?.();
  }

  close(): void {
    this.closed = true;
    this.wake?.();
  }

  private saved(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.waiters.push({ resolve, reject });
      void this.drain();
    });
  }

  private async drain(): Promise<void> {
    if (this.writing) return;
    this.writing = true;

    while (this.waiters.length > 0) {
      const waiters = this.waiters;
      const batch: Batch = { entries: [...this.entries.values()], removed: [...this.removed], seq: this.seq };
      this.waiters = [];
      this.entries = new Map();
      this.removed = new Set();
      this.seq = undefined;

      try {
        await this.patiently(() => this.store.commit(batch));
        for (const waiter of waiters) waiter.resolve();
      } catch (error) {
        for (const waiter of waiters) waiter.reject(error);
      }
    }

    this.writing = false;
  }

  private async patiently<T>(work: () => Promise<T>): Promise<T> {
    for (let wait = this.retryMs; ; wait = Math.min(wait * 2, LONGEST_RETRY_MS)) {
      if (this.closed) throw new Abandoned();
      try {
        const result = await work();
        this.report(null);
        return result;
      } catch (error) {
        if (this.closed) throw new Abandoned();
        this.report(error instanceof Error ? error.message : String(error));
        await this.rest(wait);
      }
    }
  }

  private report(trouble: string | null): void {
    if ((trouble !== null) === this.troubled) return;
    this.troubled = trouble !== null;
    this.onTrouble(trouble);
  }

  private rest(ms: number): Promise<void> {
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(timer);
        this.wake = null;
        resolve();
      };
      const timer = setTimeout(done, ms);
      this.wake = done;
    });
  }
}
