defmodule BabelSyncWeb.Paths do
  @moduledoc false

  alias BabelSync.Vaults.Entry

  def vault(vault_id), do: "/v/#{vault_id}"
  def settings(vault_id), do: "/v/#{vault_id}/settings"
  def trash(vault_id), do: "/v/#{vault_id}/trash"
  def entry(%Entry{vault_id: vault_id, path: path}), do: "/v/#{vault_id}/f/#{encode(path)}"
  def raw(%Entry{vault_id: vault_id, path: path}), do: "/v/#{vault_id}/raw/#{encode(path)}"

  defp encode(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
  end
end
