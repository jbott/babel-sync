defmodule BabelSyncWeb.Plugs.CORS do
  @moduledoc """
  Lets browser-based OAuth and MCP clients on other origins reach the
  endpoints meant for them. Those endpoints only act on a bearer token or
  on values the caller already holds, never on the session cookie.
  """

  @behaviour Plug

  import Plug.Conn

  @prefixes ["/.well-known/", "/oauth/token", "/oauth/register", "/oauth/revoke", "/mcp"]

  @headers [
    {"access-control-allow-origin", "*"},
    {"access-control-allow-methods", "GET, POST, DELETE, OPTIONS"},
    {"access-control-allow-headers",
     "authorization, content-type, accept, mcp-session-id, mcp-protocol-version, last-event-id"},
    {"access-control-expose-headers", "mcp-session-id, www-authenticate"},
    {"access-control-max-age", "600"}
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    if String.starts_with?(path, @prefixes) or
         Regex.match?(~r|\A/api/vaults/[0-9a-f-]{36}/connections/[0-9a-f-]{36}\z|, path),
       do: open(conn),
       else: conn
  end

  defp open(%Plug.Conn{method: "OPTIONS"} = conn) do
    conn |> merge_resp_headers(@headers) |> send_resp(:no_content, "") |> halt()
  end

  defp open(conn), do: merge_resp_headers(conn, @headers)
end
