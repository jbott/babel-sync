defmodule BabelSyncWeb.FileController do
  use BabelSyncWeb, :controller

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Blobs, Sync, Vaults}
  alias BabelSync.Vaults.Entry

  def raw(conn, %{"vault_id" => vault_id, "path" => segments}) do
    with %Scope{} = scope <- conn.assigns.current_scope,
         {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         :ok <- Scope.authorize(scope, vault_id, :read),
         %Entry{} = entry <- Vaults.get_entry_by_path(vault_id, Enum.join(segments, "/")) do
      deliver(conn, entry)
    else
      _missing -> send_resp(conn, :not_found, "Not found")
    end
  end

  defp deliver(conn, %Entry{kind: :blob, blob_hash: hash} = entry) when is_binary(hash) do
    case Blobs.get(entry.vault_id, hash) do
      nil -> send_resp(conn, :not_found, "Not found")
      blob -> BabelSyncWeb.BlobSender.send_blob(conn, blob, MIME.from_path(entry.path))
    end
  end

  defp deliver(conn, %Entry{kind: :doc} = entry) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(200, Sync.text(entry.id))
  end

  defp deliver(conn, _entry), do: send_resp(conn, :not_found, "Not found")
end
