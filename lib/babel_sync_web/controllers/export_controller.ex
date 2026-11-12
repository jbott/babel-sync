defmodule BabelSyncWeb.ExportController do
  @moduledoc """
  Sends a whole vault as a ZIP of plain files: notes as the Markdown or
  text they hold now, attachments as their bytes, and empty folders.
  It is what Obsidian would have on disk, so it opens as a vault.
  """

  use BabelSyncWeb, :controller

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Blobs, Sync, Vaults, Zip}
  alias BabelSync.Vaults.Entry

  @batch 200

  def show(conn, %{"vault_id" => vault_id}) do
    with %Scope{} = scope <- conn.assigns.current_scope,
         {:ok, vault_id} <- Ecto.UUID.cast(vault_id),
         :ok <- Scope.authorize(scope, vault_id, :read),
         %{} = vault <- Vaults.get_vault(vault_id) do
      conn =
        conn
        |> put_resp_content_type("application/zip")
        |> put_resp_header("content-disposition", disposition(vault.name))
        |> send_chunked(200)

      vault_id
      |> Vaults.list_entries()
      |> Stream.chunk_every(@batch)
      |> Stream.flat_map(&files/1)
      |> Zip.stream()
      |> Enum.reduce_while(conn, fn data, conn ->
        case chunk(conn, data) do
          {:ok, conn} -> {:cont, conn}
          {:error, _closed} -> {:halt, conn}
        end
      end)
    else
      _denied -> send_resp(conn, :not_found, "Not found")
    end
  end

  defp files(entries) do
    texts = Sync.texts(for %Entry{kind: :doc, id: id} <- entries, do: id)

    Enum.flat_map(entries, fn
      %Entry{kind: :folder, path: path} ->
        [{:folder, path}]

      %Entry{kind: :doc, id: id, path: path} ->
        text = Map.get(texts, id, "")
        [{path, byte_size(text), [text]}]

      %Entry{kind: :blob, path: path} = entry ->
        case entry.blob_hash && Blobs.get(entry.vault_id, entry.blob_hash) do
          %Blobs.Blob{} = blob -> [{path, blob.size, Blobs.stream(blob)}]
          _missing -> []
        end
    end)
  end

  defp disposition(name) do
    plain = String.replace(name, ~r/[^\w .-]/u, "_")

    ~s(attachment; filename="#{plain}.zip"; filename*=UTF-8''#{URI.encode(name <> ".zip", &URI.char_unreserved?/1)})
  end
end
