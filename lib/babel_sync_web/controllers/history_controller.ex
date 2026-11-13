defmodule BabelSyncWeb.HistoryController do
  @moduledoc """
  The saved versions of a note for the Obsidian plugin's history pane:
  the list, what one version changed, and putting one back.
  """

  use BabelSyncWeb, :controller

  alias BabelSync.Accounts.Scope
  alias BabelSync.{History, Sync, Vaults}
  alias BabelSync.Sync.Changes
  alias BabelSync.Vaults.Entry

  def index(conn, %{"vault_id" => vault_id, "entry_id" => entry_id}) do
    with {:ok, entry} <- note(conn, vault_id, entry_id, :read) do
      versions =
        for version <- History.versions(entry.id) do
          %{version | saved_at: DateTime.to_iso8601(version.saved_at)}
        end

      json(conn, %{versions: versions})
    end
    |> respond(conn)
  end

  def show(conn, %{"vault_id" => vault_id, "entry_id" => entry_id, "id" => id} = params) do
    against = if params["against"] == "now", do: :now, else: :previous

    with {:ok, entry} <- note(conn, vault_id, entry_id, :read),
         {id, ""} <- Integer.parse(id),
         {:ok, found} <- History.compare(entry.id, id, against) do
      json(conn, %{
        id: found.version.id,
        saved_at: DateTime.to_iso8601(found.version.inserted_at),
        text: found.text,
        changes: Changes.to_json(found.changes)
      })
    end
    |> respond(conn)
  end

  def restore(conn, %{"vault_id" => vault_id, "entry_id" => entry_id, "id" => id}) do
    with {:ok, entry} <- note(conn, vault_id, entry_id, :write),
         :ok <- Scope.authorize_write(conn.assigns.current_scope, vault_id, entry.path),
         {id, ""} <- Integer.parse(id),
         :ok <- Sync.restore_version(entry.id, id, Scope.author(conn.assigns.current_scope)) do
      json(conn, %{restored: id})
    end
    |> respond(conn)
  end

  defp note(conn, vault_id, entry_id, access) do
    with {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         {:ok, entry_id} <- Ecto.UUID.cast(entry_id),
         :ok <- Scope.authorize(conn.assigns.current_scope, vault_id, access),
         %Entry{kind: :doc, vault_id: ^vault_id, deleted_at: nil} = entry <-
           Vaults.get_entry(entry_id) do
      {:ok, entry}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _other -> {:error, :not_found}
    end
  end

  defp respond(%Plug.Conn{} = sent, _conn), do: sent

  defp respond({:error, :forbidden}, conn),
    do: conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

  defp respond(_missing, conn),
    do: conn |> put_status(:not_found) |> json(%{error: "not_found"})
end
