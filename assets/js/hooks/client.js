import { BabelSyncClient } from "@babelsync/core";
import { openNotes } from "./open_notes";

let client = null;
let currentToken = null;

export function sharedClient(token) {
  currentToken = token;

  if (!client) {
    client = new BabelSyncClient({ baseUrl: window.location.origin, token: () => currentToken });
    client.connect();
  }

  return client;
}

const leftUnsent = new Map();

export function openNote(token, entryId) {
  const kept = leftUnsent.get(entryId);
  if (kept) {
    leftUnsent.delete(entryId);
    kept.stopWaiting();
    return kept.session;
  }

  const session = sharedClient(token).doc(entryId);
  openNotes.add(session);
  return session;
}

export function closeNote(session) {
  session.awareness.setLocalState(null);
  if (!session.pending) return finish(session);

  const stopWaiting = session.on("synced", (synced) => {
    if (!synced || leftUnsent.get(session.entryId)?.session !== session) return;
    leftUnsent.delete(session.entryId);
    stopWaiting();
    finish(session);
  });
  leftUnsent.set(session.entryId, { session, stopWaiting });
}

function finish(session) {
  openNotes.delete(session);
  session.close();
}
