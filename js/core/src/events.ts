export type Listener<T> = (value: T) => void;

export class Emitter<Events extends Record<string, unknown>> {
  private listeners = new Map<keyof Events, Set<Listener<any>>>();

  on<K extends keyof Events>(event: K, listener: Listener<Events[K]>): () => void {
    const set = this.listeners.get(event) ?? new Set();
    set.add(listener);
    this.listeners.set(event, set);
    return () => set.delete(listener);
  }

  protected emit<K extends keyof Events>(event: K, value: Events[K]): void {
    for (const listener of this.listeners.get(event) ?? []) listener(value);
  }
}
