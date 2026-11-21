type CheckCallbacks = {
  active: () => boolean;
  verify: () => Promise<boolean>;
  checking: () => void;
  waiting: () => void;
  connected: () => void | Promise<void>;
  failed: (error: unknown) => void;
};

export class ConnectionCheck {
  private callbacks: CheckCallbacks;
  private timer?: ReturnType<typeof setTimeout>;
  private running = false;
  private pending = false;
  private forced = false;
  private blocked = false;
  private finished = false;
  private nextAttempt = 0;

  constructor(callbacks: CheckCallbacks) {
    this.callbacks = callbacks;
  }

  get stopped(): boolean {
    return this.finished;
  }

  schedule(force = false): void {
    if (this.finished) return;
    if (!this.callbacks.active()) return this.stop();
    if (this.blocked && !force) return;
    this.blocked = false;
    this.pending = true;
    this.forced ||= force;
    if (this.running) return;
    clearTimeout(this.timer);
    const delay = this.forced ? 0 : Math.max(750, this.nextAttempt - Date.now());
    this.timer = setTimeout(() => void this.check(), delay);
  }

  stop(): void {
    this.finished = true;
    this.pending = false;
    clearTimeout(this.timer);
    this.timer = undefined;
  }

  private async check(): Promise<void> {
    this.timer = undefined;
    if (this.finished || !this.callbacks.active()) return this.stop();
    this.running = true;
    this.pending = false;
    this.forced = false;
    this.nextAttempt = Date.now() + 5000;
    this.callbacks.checking();
    try {
      const connected = await this.callbacks.verify();
      if (this.finished || !this.callbacks.active()) return this.stop();
      if (connected) {
        this.stop();
        await this.callbacks.connected();
      } else {
        this.callbacks.waiting();
      }
    } catch (error) {
      if (this.finished || !this.callbacks.active()) return this.stop();
      this.blocked = true;
      this.callbacks.failed(error);
    } finally {
      this.running = false;
      if (this.pending && (!this.blocked || this.forced)) this.schedule(this.forced);
    }
  }
}
