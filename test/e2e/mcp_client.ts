import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

export type Agent = {
  client: Client;
  call: (tool: string, args: Record<string, unknown>) => Promise<{ text: string; failed: boolean }>;
  read: (path: string, args?: Record<string, unknown>) => Promise<{ header: string; text: string; rev: string }>;
  close: () => Promise<void>;
};

export async function connectAgent(baseUrl: string, token: string): Promise<Agent> {
  const client = new Client({ name: "babelsync-test-agent", version: "1.0.0" });
  const transport = new StreamableHTTPClientTransport(new URL("/mcp", baseUrl), {
    requestInit: { headers: { authorization: `Bearer ${token}` } },
  });
  await client.connect(transport);

  const call: Agent["call"] = async (tool, args) => {
    const result = await client.callTool({ name: tool, arguments: args });
    const content = result.content as { type: string; text?: string }[];
    return { text: content.map((part) => part.text ?? "").join("\n"), failed: result.isError === true };
  };

  return {
    client,
    call,
    read: async (path, args = {}) => {
      const result = await client.callTool({ name: "read_file", arguments: { path, ...args } });
      const [header, body] = result.content as { text: string }[];
      return { header: header.text, text: body.text, rev: header.text.split(" · rev ")[1] };
    },
    close: () => client.close(),
  };
}
