defmodule BabelSyncWeb.Plugs.Secure do
  @moduledoc """
  Sends browsers to HTTPS when the server's address is an HTTPS one,
  and leaves a plain HTTP address, such as a machine on a home network,
  alone.

  The scheme a reverse proxy reports in `x-forwarded-proto` is believed
  only from a proxy on the same machine, since anyone can send the
  header.
  """

  @behaviour Plug

  import Bitwise

  @impl true
  def init(_opts) do
    %{
      ssl: Plug.SSL.init(host: {BabelSyncWeb.Endpoint, :host, []}, exclude: [hosts: []]),
      proto: Plug.RewriteOn.init([:x_forwarded_proto])
    }
  end

  @impl true
  def call(conn, %{ssl: ssl, proto: proto}) do
    conn = if loopback?(conn.remote_ip), do: Plug.RewriteOn.call(conn, proto), else: conn

    if BabelSyncWeb.Endpoint.config(:url)[:scheme] == "https" and not local?(conn.host),
      do: Plug.SSL.call(conn, ssl),
      else: conn
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65_535, a, _}), do: a >>> 8 == 127
  defp loopback?(_remote), do: false

  defp local?(host), do: host in ["localhost", "127.0.0.1", "::1"]
end
