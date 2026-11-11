import assert from "node:assert/strict";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { connectAgent } from "./mcp_client.ts";

const baseUrl = process.env.BABELSYNC_URL!;
const token = process.env.BABELSYNC_TOKEN!;
const readOnlyToken = process.env.BABELSYNC_READ_TOKEN!;

test("the official client negotiates, lists tools and works a vault", async () => {
  const agent = await connectAgent(baseUrl, token);
  assert.equal(agent.client.getServerVersion()?.name, "BabelSync");
  assert.ok(agent.client.getServerCapabilities()?.tools);

  const { tools } = await agent.client.listTools();
  const names = tools.map((tool) => tool.name).sort();
  assert.deepEqual(names, [
    "append_note",
    "delete_file",
    "edit_note",
    "list_files",
    "list_vaults",
    "move_file",
    "note_history",
    "read_note",
    "search_notes",
    "write_note",
  ]);
  for (const tool of tools) {
    assert.ok(tool.description && tool.description.length > 20, `${tool.name} has a description`);
    assert.equal(tool.inputSchema.type, "object");
  }
  const edit = tools.find((tool) => tool.name === "edit_note")!;
  assert.deepEqual([...(edit.inputSchema.required as string[])].sort(), ["new_text", "old_text", "path"]);

  assert.match((await agent.call("list_vaults", {})).text, /Agent vault/);
  assert.equal((await agent.call("write_note", { path: "Plans/trip.md", content: "# Trip\r\n\r\n- book flights 😀\n" })).failed, false);
  assert.equal((await agent.call("read_note", { path: "Plans/trip.md" })).text, "# Trip\n\n- book flights 😀\n");
  assert.equal((await agent.call("edit_note", { path: "Plans/trip.md", old_text: "book flights", new_text: "book trains" })).failed, false);
  assert.equal((await agent.call("append_note", { path: "Plans/trip.md", content: "- pack" })).failed, false);
  assert.equal((await agent.call("read_note", { path: "Plans/trip.md" })).text, "# Trip\n\n- book trains 😀\n- pack");

  const found = JSON.parse((await agent.call("search_notes", { query: "TRAINS" })).text);
  assert.equal(found[0].path, "Plans/trip.md");
  assert.match(found[0].matches[0], /book trains/);

  const history = JSON.parse((await agent.call("note_history", { path: "Plans/trip.md" })).text);
  assert.ok(history.length >= 3);
  const first = history.at(-1).version;
  assert.equal((await agent.call("note_history", { path: "Plans/trip.md", version: first })).text, "# Trip\n\n- book flights 😀\n");

  assert.match((await agent.call("move_file", { from: "Plans/trip.md", to: "Done/trip.md" })).text, /Done\/trip.md/);
  assert.match((await agent.call("list_files", { folder: "Done" })).text, /Done\/trip.md/);

  const missing = await agent.call("read_note", { path: "Plans/trip.md" });
  assert.equal(missing.failed, true);
  assert.match(missing.text, /list_files/);
  const ambiguous = await agent.call("edit_note", { path: "Done/trip.md", old_text: "- ", new_text: "* " });
  assert.equal(ambiguous.failed, true);
  assert.match(ambiguous.text, /more than once/);

  await assert.rejects(agent.client.callTool({ name: "edit_note", arguments: { path: "Done/trip.md" } }));
  await assert.rejects(agent.client.callTool({ name: "no_such_tool", arguments: {} }));

  assert.equal((await agent.call("delete_file", { path: "Done/trip.md" })).failed, false);
  await agent.close();
});

test("many agents at once append to one note without losing a line", async () => {
  const agents = await Promise.all(Array.from({ length: 6 }, () => connectAgent(baseUrl, token)));
  await agents[0].call("write_note", { path: "log.md", content: "start\n" });

  await Promise.all(
    agents.flatMap((agent, who) =>
      Array.from({ length: 10 }, (_, n) => agent.call("append_note", { path: "log.md", content: `agent ${who} line ${n}\n` })),
    ),
  );

  const lines = (await agents[0].call("read_note", { path: "log.md" })).text.split("\n").filter(Boolean);
  assert.equal(lines.length, 61);
  assert.equal(new Set(lines).size, 61);
  await Promise.all(agents.map((agent) => agent.close()));
});

test("a read-only credential reads but cannot change anything", async () => {
  const writer = await connectAgent(baseUrl, token);
  await writer.call("write_note", { path: "fixed.md", content: "do not touch\n" });
  const reader = await connectAgent(baseUrl, readOnlyToken);

  assert.equal((await reader.call("read_note", { path: "fixed.md" })).text, "do not touch\n");
  for (const [tool, args] of [
    ["write_note", { path: "fixed.md", content: "x" }],
    ["edit_note", { path: "fixed.md", old_text: "touch", new_text: "x" }],
    ["append_note", { path: "fixed.md", content: "x" }],
    ["move_file", { from: "fixed.md", to: "y.md" }],
    ["delete_file", { path: "fixed.md" }],
  ] as const) {
    assert.equal((await reader.call(tool, args)).failed, true, tool);
  }
  assert.equal((await writer.call("read_note", { path: "fixed.md" })).text, "do not touch\n");
  await Promise.all([reader.close(), writer.close()]);
});

test("a client without a credential is told where to sign in", async () => {
  const client = new Client({ name: "anonymous", version: "1.0.0" });
  const response = await fetch(new URL("/mcp", baseUrl), {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream", origin: "https://elsewhere.example" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }),
  });
  assert.equal(response.status, 401);
  assert.match(response.headers.get("www-authenticate") ?? "", /resource_metadata="[^"]+\/\.well-known\/oauth-protected-resource/);

  const transport = new StreamableHTTPClientTransport(new URL("/mcp", baseUrl), {
    requestInit: { headers: { authorization: "Bearer bsa_not-a-real-token" } },
  });
  await assert.rejects(client.connect(transport));
});
