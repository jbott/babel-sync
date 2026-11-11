import type { Channel, Socket } from "phoenix";
import * as Y from "yjs";
import {
  Awareness,
  applyAwarenessUpdate,
  encodeAwarenessUpdate,
  removeAwarenessStates,
} from "y-protocols/awareness";
import { Emitter } from "./events.ts";
import { fromBase64, toArrayBuffer, toBase64 } from "./encoding.ts";

export const TEXT_NAME = "content";

type JoinReply = { update: string; sv: string; writable: boolean };

type DocEvents = {
  synced: boolean;
  writable: boolean;
  error: string;
};

export class DocSession extends Emitter<DocEvents> {
  readonly doc: Y.Doc;
  readonly text: Y.Text;
  readonly awareness: Awareness;
  readonly entryId: string;
  writable = true;

  private channel: Channel;
  private joined = false;
  private unacknowledged = 0;
  private closed = false;

  constructor(socket: Socket, entryId: string, doc: Y.Doc = new Y.Doc()) {
    super();
    this.entryId = entryId;
    this.doc = doc;
    this.text = doc.getText(TEXT_NAME);
    this.awareness = new Awareness(doc);

    this.channel = socket.channel(`doc:${entryId}`, () => ({
      sv: toBase64(Y.encodeStateVector(this.doc)),
    }));

    this.channel.on("update", (payload: ArrayBuffer) => {
      Y.applyUpdate(this.doc, new Uint8Array(payload), this);
    });

    this.channel.on("awareness", (payload: ArrayBuffer) => {
      applyAwarenessUpdate(this.awareness, new Uint8Array(payload), this);
    });

    this.channel.onClose(() => this.left());
    this.channel.onError(() => this.left());

    this.doc.on("update", this.onLocalUpdate);
    this.awareness.on("update", this.onAwarenessUpdate);

    this.channel
      .join()
      .receive("ok", (reply: JoinReply) => this.onJoin(reply))
      .receive("error", (reply: { reason?: string }) => this.emit("error", reply.reason ?? "error"));
  }

  get synced(): boolean {
    return this.joined && this.unacknowledged === 0;
  }

  whenSynced(timeoutMs = 15000): Promise<void> {
    if (this.synced) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const finish = (error?: Error) => {
        clearTimeout(timer);
        stopReady();
        stopError();
        if (error) reject(error);
        else resolve();
      };
      const timer = setTimeout(() => finish(new Error("timed out waiting for synced")), timeoutMs);
      const stopReady = this.on("synced", () => {
        if (this.synced) finish();
      });
      const stopError = this.on("error", (reason) => finish(new Error(reason)));
    });
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.doc.off("update", this.onLocalUpdate);
    this.awareness.off("update", this.onAwarenessUpdate);
    removeAwarenessStates(this.awareness, [this.doc.clientID], this);
    this.channel.leave();
    this.awareness.destroy();
  }

  private onJoin(reply: JoinReply): void {
    this.joined = true;
    this.unacknowledged = 0;
    this.writable = reply.writable;
    this.emit("writable", reply.writable);

    Y.applyUpdate(this.doc, fromBase64(reply.update), this);

    const missingOnServer = Y.encodeStateAsUpdate(this.doc, fromBase64(reply.sv));
    if (reply.writable && !isEmptyUpdate(missingOnServer)) this.send(missingOnServer);

    if (this.awareness.getLocalState() !== null) {
      this.sendAwareness([this.doc.clientID]);
    }

    this.emit("synced", this.synced);
  }

  private left(): void {
    if (!this.joined) return;
    this.joined = false;
    const others = [...this.awareness.getStates().keys()].filter((id) => id !== this.doc.clientID);
    removeAwarenessStates(this.awareness, others, this);
    this.emit("synced", false);
  }

  private onLocalUpdate = (update: Uint8Array, origin: unknown): void => {
    if (origin === this || !this.joined || !this.writable) return;
    this.send(update);
  };

  private onAwarenessUpdate = (
    changes: { added: number[]; updated: number[]; removed: number[] },
    origin: unknown,
  ): void => {
    if (origin === this || !this.joined) return;
    this.sendAwareness([...changes.added, ...changes.updated, ...changes.removed]);
  };

  private send(update: Uint8Array): void {
    this.unacknowledged += 1;
    if (this.unacknowledged === 1) this.emit("synced", false);

    this.channel
      .push("update", toArrayBuffer(update) as unknown as object)
      .receive("ok", () => this.acknowledged())
      .receive("error", (reply: { reason?: string }) => {
        this.acknowledged();
        this.emit("error", reply.reason ?? "error");
      });
  }

  private acknowledged(): void {
    this.unacknowledged = Math.max(0, this.unacknowledged - 1);
    if (this.synced) this.emit("synced", true);
  }

  private sendAwareness(clients: number[]): void {
    const update = encodeAwarenessUpdate(this.awareness, clients);
    this.channel.push("awareness", toArrayBuffer(update) as unknown as object);
  }
}

function isEmptyUpdate(update: Uint8Array): boolean {
  return update.length === 2 && update[0] === 0 && update[1] === 0;
}
