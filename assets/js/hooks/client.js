import { BabelSyncClient } from "@babelsync/core";

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

const openNotes = new Set();

export function track(session) {
  openNotes.add(session);
  return () => openNotes.delete(session);
}

export function allNotesSaved(timeoutMs) {
  return Promise.all([...openNotes].map((session) => session.whenSynced(timeoutMs)));
}
