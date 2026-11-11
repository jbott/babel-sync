defmodule BabelSyncWeb.BlobController do
  use BabelSyncWeb, :controller

  alias BabelSync.Accounts.Scope
  alias BabelSync.Blobs

  plug :authorize

  def begin(conn, %{"hash" => hash, "size" => size}) do
    case Blobs.begin_upload(conn.assigns.vault_id, %{hash: hash, size: size}) do
      {:exists, _blob} ->
        json(conn, %{status: "exists"})

      {:ok, upload, missing} ->
        json(conn, %{
          status: "upload",
          id: upload.id,
          part_size: upload.part_size,
          missing: missing
        })

      {:error, :too_large} ->
        fail(conn, :request_entity_too_large, "too_large")

      {:error, _invalid} ->
        fail(conn, :unprocessable_entity, "invalid")
    end
  end

  def begin(conn, _params), do: fail(conn, :unprocessable_entity, "invalid")

  def part(conn, %{"id" => id, "number" => number}) do
    with {:ok, upload} <- upload(conn, id),
         {number, ""} <- Integer.parse(number),
         {:ok, data, conn} <- read_all(conn, upload.part_size),
         :ok <- Blobs.put_part(upload, number, data) do
      send_resp(conn, :no_content, "")
    else
      {:error, :not_found} -> fail(conn, :not_found, "not_found")
      {:error, :too_large, conn} -> fail(conn, :request_entity_too_large, "too_large")
      {:error, reason} when is_atom(reason) -> fail(conn, :unprocessable_entity, "#{reason}")
      _invalid -> fail(conn, :unprocessable_entity, "invalid")
    end
  end

  def complete(conn, %{"id" => id}) do
    with {:ok, upload} <- upload(conn, id),
         {:ok, blob} <- Blobs.complete_upload(upload) do
      json(conn, %{hash: blob.hash, size: blob.size})
    else
      {:error, :not_found} ->
        fail(conn, :not_found, "not_found")

      {:error, {:missing, missing}} ->
        conn |> put_status(:conflict) |> json(%{error: "missing_parts", missing: missing})

      {:error, :hash_mismatch} ->
        fail(conn, :unprocessable_entity, "hash_mismatch")

      {:error, _reason} ->
        fail(conn, :bad_gateway, "storage")
    end
  end

  def show(conn, %{"hash" => hash}) do
    case Blobs.get(conn.assigns.vault_id, hash) do
      nil -> fail(conn, :not_found, "not_found")
      blob -> BabelSyncWeb.BlobSender.send_blob(conn, blob, "application/octet-stream")
    end
  end

  defp authorize(conn, _opts) do
    access = if conn.method in ["GET", "HEAD"], do: :read, else: :write

    with {:ok, vault_id} <- Ecto.UUID.cast(conn.params["vault_id"]),
         :ok <- Scope.authorize(conn.assigns.current_scope, vault_id, access) do
      assign(conn, :vault_id, vault_id)
    else
      _denied -> conn |> fail(:forbidden, "forbidden") |> halt()
    end
  end

  defp upload(conn, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Blobs.Upload{vault_id: vault_id} = upload <- Blobs.get_upload(id),
         true <- vault_id == conn.assigns.vault_id do
      {:ok, upload}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp read_all(conn, limit, read \\ []) do
    case read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {:ok, data, conn} -> within(conn, limit, [data | read], :done)
      {:more, data, conn} -> within(conn, limit, [data | read], :more)
      {:error, _reason} -> :error
    end
  end

  defp within(conn, limit, read, progress) do
    cond do
      IO.iodata_length(read) > limit -> {:error, :too_large, conn}
      progress == :more -> read_all(conn, limit, read)
      true -> {:ok, read |> Enum.reverse() |> IO.iodata_to_binary(), conn}
    end
  end

  defp fail(conn, status, error) do
    conn |> put_status(status) |> json(%{error: error})
  end
end
