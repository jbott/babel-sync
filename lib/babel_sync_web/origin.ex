defmodule BabelSyncWeb.Origin do
  @moduledoc """
  Decides which pages may open the sync socket. Besides the server's own
  pages that is the Obsidian app, whose desktop and mobile shells load
  from fixed non-web origins.
  """

  @obsidian [
    {"app", "obsidian.md"},
    {"capacitor", "localhost"},
    {"http", "localhost"}
  ]

  @loopback ["localhost", "127.0.0.1", "::1"]

  @spec allowed?(URI.t()) :: boolean()
  def allowed?(%URI{scheme: scheme, host: host}) do
    {scheme, host} in @obsidian or host in @loopback or
      host == BabelSyncWeb.Endpoint.config(:url)[:host]
  end
end
