import type { Batch, MemoryStore, StateStore } from "../src/fs.ts";

export const STORE_FAULT = "The database connection is closing.";

const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export class FlakyStore implements StateStore {
  refused = 0;
  private inner: MemoryStore;
  private chance: () => number;
  private outUntil = 0;
  private slow = false;

  constructor(inner: MemoryStore, chance: () => number) {
    this.inner = inner;
    this.chance = chance;
  }

  private async falter(): Promise<void> {
    if (Date.now() >= this.outUntil && this.chance() < 0.08) {
      this.outUntil = Date.now() + 20 + this.chance() * 600;
      this.slow = this.chance() < 0.5;
    }
    if (Date.now() >= this.outUntil) return;
    if (this.slow) return void (await pause(this.outUntil - Date.now()));

    this.refused += 1;
    if (this.chance() < 0.3) await pause(this.chance() * 80);
    throw new Error(STORE_FAULT);
  }

  shut(): void {
    this.outUntil = Infinity;
    this.slow = false;
  }

  async load() {
    await this.falter();
    return this.inner.load();
  }

  async commit(batch: Batch) {
    await this.falter();
    return this.inner.commit(batch);
  }
}
