defmodule BabelSync.Obsidian.Plugin do
  @moduledoc """
  The Obsidian plugin as this server hands it out, so that a device can
  be set up from the server it will sync with and nothing has to be
  copied by hand.

  Two archives are offered. One is the plugin alone, to drop into a vault
  that already exists. The other is a whole new vault folder with the
  plugin installed, switched on and already pointed at this server and
  one of its vaults, which is the only practical way to install a plugin
  on a phone.
  """

  alias BabelSync.Vaults.Vault

  @id "babelsync"
  @files ~w(main.js manifest.json)

  @spec available?() :: boolean()
  def available?, do: Enum.all?(@files, &File.regular?(path(&1)))

  @spec version() :: String.t() | nil
  def version do
    with {:ok, manifest} <- File.read(path("manifest.json")),
         {:ok, %{"version" => version}} <- Jason.decode(manifest) do
      version
    else
      _missing -> nil
    end
  end

  @spec archive() :: {:ok, binary()} | {:error, :unavailable}
  def archive, do: zip(fn name -> Path.join(@id, name) end, [])

  @spec starter_vault(Vault.t(), String.t()) ::
          {:ok, String.t(), binary()} | {:error, :unavailable}
  def starter_vault(%Vault{} = vault, server_url) do
    folder = folder_name(vault.name)
    config = Path.join(folder, ".obsidian")

    settings =
      Jason.encode!(%{serverUrl: server_url, vaultId: vault.id, vaultName: vault.name},
        pretty: true
      )

    extra = [
      {Path.join(config, "community-plugins.json"), Jason.encode!([@id])},
      {Path.join([config, "plugins", @id, "data.json"]), settings}
    ]

    with {:ok, archive} <- zip(&Path.join([config, "plugins", @id, &1]), extra) do
      {:ok, folder, archive}
    end
  end

  @spec folder_name(String.t()) :: String.t()
  def folder_name(name) do
    cleaned =
      name
      |> String.replace(~r/[\\\/:*?"<>|\x00-\x1f]/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.replace(~r/^[\s.]+|[\s.]+$/u, "")
      |> String.slice(0, 80)

    if cleaned == "", do: "BabelSync vault", else: cleaned
  end

  defp zip(place, extra) do
    if available?() do
      plugin = for name <- @files, do: {place.(name), File.read!(path(name))}
      entries = for {name, data} <- plugin ++ extra, do: {String.to_charlist(name), data}
      {:ok, {_name, archive}} = :zip.create(~c"archive.zip", entries, [:memory])
      {:ok, archive}
    else
      {:error, :unavailable}
    end
  end

  defp path(name), do: Path.join(directory(), name)

  defp directory do
    configured = Application.get_env(:babel_sync, __MODULE__, [])[:directory]
    configured || Application.app_dir(:babel_sync, "priv/plugin")
  end
end
