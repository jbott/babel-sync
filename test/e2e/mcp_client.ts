import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

export type Agent = {
  client: Client;
  call: (tool: string, args: Record<string, unknown>) => Promise<{ text: string; failed: boolean }>;
  close: () => Promise<void>;
};

export async function connectAgent(baseUrl: string, token: string): Promise<Agent> {
  const client = new Client({ name: "babelsync-test-agent", version: "1.0.0" });
  const transport = new StreamableHTTPClientTransport(new URL("/mcp", baseUrl), {
    requestInit: { headers: { authorization: `Bearer ${token}` } },
  });
  await client.connect(transport);

  return {
    client,
    call: async (tool, args) => {
      const result = await client.callTool({ name: tool, arguments: args });
      const content = result.content as { type: string; text?: string }[];
      return { text: content.map((part) => part.text ?? "").join(""), failed: result.isError === true };
    },
    close: () => client.close(),
  };
}
