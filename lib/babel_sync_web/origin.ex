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

  @spec allowed?(URI.t()) :: boolean()
  def allowed?(%URI{scheme: scheme, host: host}) do
    {scheme, host} in @obsidian or own_host?(host) or unchecked?()
  end

  defp own_host?(host), do: host == BabelSyncWeb.Endpoint.config(:url)[:host]

  defp unchecked?, do: BabelSyncWeb.Endpoint.config(:check_origin) == false
end
