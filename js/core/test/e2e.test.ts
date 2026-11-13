import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import * as Y from "yjs";
import { BabelSyncClient, RequestError, blobHash } from "../src/index.ts";

const baseUrl = process.env.BABELSYNC_URL!;
const vaultId = process.env.BABELSYNC_VAULT_ID!;
const token = process.env.BABELSYNC_TOKEN!;
const phase = process.env.BABELSYNC_PHASE!;

const clients: BabelSyncClient[] = [];

function client(): BabelSyncClient {
  const created = new BabelSyncClient({ baseUrl, token: () => token, transport: WebSocket });
  created.connect();
  clients.push(created);
  return created;
}

async function eventually(check: () => boolean, what: string): Promise<void> {
  const deadline = Date.now() + 5000;
  while (!check()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

before(() => {
  assert.ok(baseUrl && vaultId && token && phase);
});

after(async () => {
  await Promise.all(clients.map((each) => each.disconnect()));
});

if (phase === "write") {
  test("a created note reaches the other client and both edit it live", async () => {
    const alice = client();
    const bob = client();
    const aliceVault = alice.vault(vaultId);
    const bobVault = bob.vault(vaultId);
    await Promise.all([aliceVault.whenJoined(), bobVault.whenJoined()]);
    assert.equal(aliceVault.writable, true);

    const entry = await aliceVault.create("Shared/live.md", { text: "a😀b 日本語\n" });
    await eventually(() => bobVault.byPath("Shared/live.md") !== undefined, "bob to see the note");

    const aliceDoc = alice.doc(entry.id);
    const bobDoc = bob.doc(entry.id);
    await Promise.all([aliceDoc.whenSynced(), bobDoc.whenSynced()]);
    assert.equal(aliceDoc.text.toString(), "a😀b 日本語\n");
    assert.equal(bobDoc.text.toString(), "a😀b 日本語\n");

    aliceDoc.text.insert("a😀".length, "😃");
    bobDoc.text.insert(bobDoc.text.length, "bob was here\n");

    await eventually(
      () => aliceDoc.text.toString() === "a😀😃b 日本語\nbob was here\n" && bobDoc.text.toString() === aliceDoc.text.toString(),
      "both editors to converge",
    );
    await Promise.all([aliceDoc.whenSynced(), bobDoc.whenSynced()]);
  });

  test("edits made offline merge when the client returns", async () => {
    const alice = client();
    const carol = client();
    const vault = alice.vault(vaultId);
    await vault.whenJoined();
    const entry = await vault.create("offline.md", { text: "line one\nline two\n" });

    const carolLocal = new Y.Doc();
    const firstVisit = carol.doc(entry.id, carolLocal);
    await firstVisit.whenSynced();
    firstVisit.close();

    carolLocal.getText("content").insert(0, "carol offline\n");
    const aliceDoc = alice.doc(entry.id);
    await aliceDoc.whenSynced();
    aliceDoc.text.insert(aliceDoc.text.length, "alice online\n");
    await aliceDoc.whenSynced();

    const secondVisit = carol.doc(entry.id, carolLocal);
    await secondVisit.whenSynced();

    const expected = "carol offline\nline one\nline two\nalice online\n";
    await eventually(() => aliceDoc.text.toString() === expected, "alice to receive carol's edit");
    assert.equal(secondVisit.text.toString(), expected);
  });

  test("a note says when it holds changes the server does not have", async () => {
    const alice = client();
    const dana = client();
    const vault = alice.vault(vaultId);
    await vault.whenJoined();
    const entry = await vault.create("pending.md", { text: "saved\n" });

    const danaDoc = dana.doc(entry.id);
    await danaDoc.whenSynced();
    assert.equal(danaDoc.connected, true);
    assert.equal(danaDoc.pending, false);

    await dana.disconnect();
    await eventually(() => !danaDoc.connected, "dana to notice she is offline");
    assert.equal(danaDoc.pending, false);
    danaDoc.text.insert(0, "typed offline\n");
    assert.equal(danaDoc.pending, true);

    dana.connect();
    await danaDoc.whenSynced();
    assert.equal(danaDoc.pending, false);
    const aliceDoc = alice.doc(entry.id);
    await aliceDoc.whenSynced();
    assert.equal(aliceDoc.text.toString(), "typed offline\nsaved\n");
  });

  test("cursors are visible to other clients", async () => {
    const alice = client();
    const bob = client();
    const vault = alice.vault(vaultId);
    await vault.whenJoined();
    const entry = await vault.create("cursors.md", { text: "hello" });
    const aliceDoc = alice.doc(entry.id);
    const bobDoc = bob.doc(entry.id);
    await Promise.all([aliceDoc.whenSynced(), bobDoc.whenSynced()]);

    aliceDoc.awareness.setLocalStateField("user", { name: "Alice" });

    await eventually(() => (bobDoc.awareness.getStates().get(aliceDoc.doc.clientID) as any)?.user?.name === "Alice", "bob to see alice's cursor");
  });

  test("a large attachment uploads in parts, downloads intact and detects conflicts", async () => {
    const alice = client();
    const vault = alice.vault(vaultId);
    await vault.whenJoined();

    const data = new Uint8Array(9 * 1024 * 1024);
    for (let offset = 0; offset < data.length; offset += 65536) {
      crypto.getRandomValues(data.subarray(offset, offset + 65536));
    }

    const progress: number[] = [];
    const hash = await alice.upload(vaultId, data, (sent) => progress.push(sent));
    assert.equal(hash, await blobHash(data));
    assert.deepEqual(progress, [8 * 1024 * 1024, data.length]);
    assert.equal(await alice.upload(vaultId, data), hash);

    const entry = await vault.create("Attachments/big.bin", { blobHash: hash });
    assert.equal(entry.kind, "blob");
    assert.equal(entry.size, data.length);
    assert.deepEqual(await alice.download(vaultId, hash), data);

    const replacement = await alice.upload(vaultId, new TextEncoder().encode("v2"));
    await vault.setBlob(entry.id, replacement, hash);
    await assert.rejects(vault.setBlob(entry.id, hash, hash), (error: unknown) => error instanceof RequestError && error.reason === "conflict");
  });

  test("renames and deletions reach other clients and a returning client catches up", async () => {
    const alice = client();
    const bob = client();
    const aliceVault = alice.vault(vaultId);
    const bobVault = bob.vault(vaultId);
    await Promise.all([aliceVault.whenJoined(), bobVault.whenJoined()]);

    const entry = await aliceVault.create("draft.md", { text: "x" });
    await eventually(() => bobVault.entries.has(entry.id), "bob to see the draft");
    const seenByBob = bobVault.seq;
    bobVault.close();

    await aliceVault.rename(entry.id, "final.md");
    const doomed = await aliceVault.create("doomed.md");
    await aliceVault.remove(doomed.id);

    const returning = bob.vault(vaultId, seenByBob);
    const changes: string[] = [];
    returning.on("joined", ({ entries }) => {
      for (const each of entries) changes.push(`${each.path}:${each.deleted}`);
    });
    await returning.whenJoined();

    assert.deepEqual(changes, ["final.md:false", "doomed.md:true"]);
  });
}

if (phase === "verify") {
  test("text rewritten by the server arrives intact", async () => {
    const reader = client();
    const vault = reader.vault(vaultId);
    await vault.whenJoined();
    const entry = vault.byPath("Shared/live.md")!;
    const doc = reader.doc(entry.id);
    await doc.whenSynced();

    assert.equal(doc.text.toString(), "a😀😃b 日本の語\nbob was here\nand the server too 🎉\n");

    doc.text.insert(doc.text.toString().indexOf("🎉"), "✅");
    await doc.whenSynced();
  });
}
