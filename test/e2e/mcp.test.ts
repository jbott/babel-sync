import assert from "node:assert/strict";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { connectAgent } from "./mcp_client.ts";

const baseUrl = process.env.BABELSYNC_URL!;
const token = process.env.BABELSYNC_TOKEN!;
const readOnlyToken = process.env.BABELSYNC_READ_TOKEN!;

test("the official client negotiates, is told how to work, and lists the tools", async () => {
  const agent = await connectAgent(baseUrl, token);
  assert.equal(agent.client.getServerVersion()?.name, "BabelSync");
  assert.ok(agent.client.getServerCapabilities()?.tools);
  assert.match(agent.client.getInstructions() ?? "", /edit_file or append_file/);

  const { tools } = await agent.client.listTools();
  const names = tools.map((tool) => tool.name).sort();
  assert.deepEqual(names, [
    "append_file",
    "create_directory",
    "delete_file",
    "edit_file",
    "file_history",
    "file_outline",
    "find_files",
    "list_changes",
    "list_directory",
    "list_trash",
    "list_vaults",
    "move_file",
    "read_file",
    "restore_file",
    "search_files",
    "write_file",
  ]);
  for (const tool of tools) {
    assert.ok(tool.description && tool.description.length > 20, `${tool.name} has a description`);
    assert.equal(tool.inputSchema.type, "object");
  }
  const edit = tools.find((tool) => tool.name === "edit_file")!;
  assert.deepEqual([...(edit.inputSchema.required as string[])].sort(), ["edits", "path"]);
  await agent.close();
});

test("an agent works a vault like a file system", async () => {
  const agent = await connectAgent(baseUrl, token);
  assert.match((await agent.call("list_vaults", {})).text, /Agent vault/);

  const created = await agent.call("write_file", { path: "Plans/trip.md", content: "# Trip\r\n\r\n## Tasks\r\n- book flights 😀\n\n## Notes\nnone\n" });
  assert.equal(created.failed, false);
  assert.match(created.text, /^created Plans\/trip\.md · rev [0-9a-f]{8} · 7 lines\n/);
  await agent.call("write_file", { path: "Plans/Old/2019.md", content: "went by train\n" });

  assert.equal((await agent.call("list_directory", {})).text, "Plans/\tfolder\t2 files");
  assert.match((await agent.call("list_directory", { path: "Plans" })).text, /^Plans\/Old\/\tfolder\t1 files\nPlans\/trip\.md\tnote\t\d+ bytes\t/);
  assert.equal((await agent.call("find_files", { pattern: "plans/**/*.md" })).text, "Plans/Old/2019.md\nPlans/trip.md");

  const whole = await agent.read("Plans/trip.md");
  assert.equal(whole.text, "# Trip\n\n## Tasks\n- book flights 😀\n\n## Notes\nnone\n");
  assert.match(whole.header, /^Plans\/trip\.md · lines 1-7 of 7 · rev [0-9a-f]{8}$/);
  assert.equal((await agent.read("Plans/trip.md", { offset: 3, limit: 2 })).text, "## Tasks\n- book flights 😀");
  assert.equal((await agent.call("file_outline", { path: "Plans/trip.md" })).text, `Plans/trip.md · 7 lines · rev ${whole.rev}\n1\t# Trip\n3\t## Tasks\n6\t## Notes`);

  const edited = await agent.call("edit_file", {
    path: "Plans/trip.md",
    edits: [
      { old_text: "book flights", new_text: "book trains" },
      { old_text: "none", new_text: "window seats" },
    ],
  });
  assert.equal(edited.failed, false);
  assert.match(edited.text, /     4\t- book trains 😀\n/);
  assert.match(edited.text, /     7\twindow seats/);

  const appended = await agent.call("append_file", { path: "Plans/trip.md", content: "- pack", heading: "Tasks" });
  assert.match(appended.text, /     5\t- pack/);
  const now = await agent.read("Plans/trip.md");
  assert.equal(now.text, "# Trip\n\n## Tasks\n- book trains 😀\n- pack\n\n## Notes\nwindow seats\n");
  assert.equal(appended.text.split(" · ")[1], `rev ${now.rev}`);

  assert.equal((await agent.call("search_files", { query: "TRAIN" })).text, "Plans/Old/2019.md\n1: went by train\n\nPlans/trip.md\n4: - book trains 😀");
  assert.equal((await agent.call("search_files", { query: "^- \\w+$", regex: true, glob: "Plans/*.md" })).text, "Plans/trip.md\n5: - pack");

  const careless = await agent.call("write_file", { path: "Plans/trip.md", content: "gone" });
  assert.equal(careless.failed, true);
  assert.match(careless.text, /Nothing was changed/);
  const stale = await agent.call("write_file", { path: "Plans/trip.md", content: "gone", if_rev: whole.rev });
  assert.equal(stale.failed, true);
  assert.match(stale.text, new RegExp(`now at rev ${now.rev}`));
  assert.equal((await agent.call("write_file", { path: "Plans/trip.md", content: "# Trip\n\nrewritten\n", if_rev: now.rev })).failed, false);

  const history = JSON.parse((await agent.call("file_history", { path: "Plans/trip.md" })).text);
  assert.ok(history.length >= 4);
  const first = history.at(-1).version;
  assert.equal((await agent.read("Plans/trip.md", { version: first })).text, whole.text);
  assert.equal((await agent.call("restore_file", { path: "Plans/trip.md", version: first })).failed, false);
  assert.equal((await agent.read("Plans/trip.md")).text, whole.text);

  const before = (await agent.call("list_changes", {})).text.split("\n")[0].replace("cursor ", "");
  assert.equal((await agent.call("move_file", { from: "Plans", to: "Done/Plans" })).text, "moved to Done/Plans");
  assert.equal((await agent.call("find_files", { pattern: "*.md" })).text, "Done/Plans/Old/2019.md\nDone/Plans/trip.md");
  assert.equal((await agent.read("Done/Plans/trip.md")).text, whole.text);
  const since = (await agent.call("list_changes", { since: Number(before) })).text;
  assert.match(since, /written\tDone\/Plans\/trip\.md\tnote/);

  const missing = await agent.call("read_file", { path: "Plans/trip.md" });
  assert.equal(missing.failed, true);
  assert.match(missing.text, /list_directory/);
  const ambiguous = await agent.call("edit_file", { path: "Done/Plans/trip.md", edits: [{ old_text: "## ", new_text: "### " }] });
  assert.equal(ambiguous.failed, true);
  assert.match(ambiguous.text, /Edit 1.*more than once/);
  assert.equal((await agent.call("edit_file", { path: "Done/Plans/trip.md", edits: [{ old_text: "## ", new_text: "### ", replace_all: true }] })).failed, false);

  await assert.rejects(agent.client.callTool({ name: "edit_file", arguments: { path: "Done/Plans/trip.md" } }));
  await assert.rejects(agent.client.callTool({ name: "edit_file", arguments: { path: "Done/Plans/trip.md", edits: [{ old_text: "x" }] } }));
  await assert.rejects(agent.client.callTool({ name: "no_such_tool", arguments: {} }));

  assert.equal((await agent.call("delete_file", { path: "Done" })).text, "deleted Done/Plans/Old/2019.md, Done/Plans/trip.md");
  assert.match((await agent.call("list_trash", {})).text, /Done\/Plans\/trip\.md\tnote\tdeleted /);
  assert.equal((await agent.call("restore_file", { path: "Done/Plans/trip.md" })).text, "restored Done/Plans/trip.md");
  assert.equal((await agent.call("delete_file", { path: "Done/Plans/trip.md" })).failed, false);
  await agent.close();
});

test("many agents at once append to one note without losing a line", async () => {
  const agents = await Promise.all(Array.from({ length: 6 }, () => connectAgent(baseUrl, token)));
  await agents[0].call("write_file", { path: "log.md", content: "# Log\n\n## Entries\nstart\n\n## Footer\nend\n" });

  await Promise.all(
    agents.flatMap((agent, who) =>
      Array.from({ length: 10 }, (_, n) =>
        n % 2 === 0
          ? agent.call("append_file", { path: "log.md", content: `agent ${who} line ${n}\n`, heading: "Entries" })
          : agent.call("edit_file", { path: "log.md", edits: [{ old_text: "end\n", new_text: `agent ${who} line ${n}\nend\n` }] }),
      ),
    ),
  );

  const text = (await agents[0].read("log.md")).text;
  const lines = text.split("\n").filter((line) => line.startsWith("agent "));
  assert.equal(lines.length, 60);
  assert.equal(new Set(lines).size, 60);
  const [entries, footer] = text.split("## Footer");
  assert.equal(entries.split("\n").filter((line) => line.startsWith("agent ")).length, 30);
  assert.equal(footer.split("\n").filter((line) => line.startsWith("agent ")).length, 30);
  await Promise.all(agents.map((agent) => agent.close()));
});

test("a read-only credential reads but cannot change anything", async () => {
  const writer = await connectAgent(baseUrl, token);
  await writer.call("write_file", { path: "fixed.md", content: "do not touch\n" });
  const reader = await connectAgent(baseUrl, readOnlyToken);

  assert.equal((await reader.read("fixed.md")).text, "do not touch\n");
  assert.equal((await reader.call("search_files", { query: "touch" })).failed, false);
  for (const [tool, args] of [
    ["write_file", { path: "fixed.md", content: "x", overwrite: true }],
    ["write_file", { path: "new.md", content: "x" }],
    ["edit_file", { path: "fixed.md", edits: [{ old_text: "touch", new_text: "x" }] }],
    ["append_file", { path: "fixed.md", content: "x" }],
    ["create_directory", { path: "Folder" }],
    ["move_file", { from: "fixed.md", to: "y.md" }],
    ["delete_file", { path: "fixed.md" }],
  ] as const) {
    assert.equal((await reader.call(tool, args)).failed, true, tool);
  }
  assert.equal((await writer.read("fixed.md")).text, "do not touch\n");
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
