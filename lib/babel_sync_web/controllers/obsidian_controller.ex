defmodule BabelSyncWeb.ObsidianController do
  use BabelSyncWeb, :controller

  alias BabelSync.Accounts.Scope
  alias BabelSync.Obsidian.Plugin
  alias BabelSync.Vaults
  alias BabelSync.Vaults.Vault

  def plugin(conn, _params) do
    with %Scope{} <- conn.assigns.current_scope,
         {:ok, archive} <- Plugin.archive() do
      download(conn, "babelsync-plugin.zip", archive)
    else
      _refused -> send_resp(conn, :not_found, "Not found")
    end
  end

  def build(conn, _params) do
    json(conn, %{version: Plugin.version(), build: Plugin.build()})
  end

  def file(conn, %{"name" => name}) do
    case Plugin.file(name) do
      {:ok, data} ->
        conn
        |> put_resp_content_type(MIME.from_path(name))
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(:ok, data)

      {:error, :unavailable} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def starter(conn, %{"vault_id" => vault_id}) do
    with %Scope{} = scope <- conn.assigns.current_scope,
         {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         :ok <- Scope.authorize(scope, vault_id, :read),
         %Vault{} = vault <- Vaults.get_vault(vault_id),
         {:ok, folder, archive} <- Plugin.starter_vault(vault, BabelSyncWeb.Endpoint.url()) do
      download(conn, folder <> ".zip", archive)
    else
      _refused -> send_resp(conn, :not_found, "Not found")
    end
  end

  defp download(conn, name, archive) do
    conn
    |> put_resp_content_type("application/zip")
    |> put_resp_header("cache-control", "no-store")
    |> send_download({:binary, archive}, filename: name)
  end
end
