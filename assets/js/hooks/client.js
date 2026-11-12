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
