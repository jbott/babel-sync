defmodule BabelSyncWeb.TransferController do
  @moduledoc """
  Moves a file's bytes for an agent through a link from upload_file,
  download_file or read_file. The link's handle is the only credential;
  what it allows is looked up on the server, and access to the vault is
  checked again here.

  An upload's body is streamed to a file in the data directory, because
  a blob is named by a hash of its contents and the name is needed
  before it can go to storage. From there it is stored in parts, as a
  device's upload is, so on S3 it becomes a multipart upload.
  """

  use BabelSyncWeb, :controller

  alias BabelSync.Accounts
  alias BabelSync.Accounts.Scope
  alias BabelSync.{Agent, Blobs, Sync, Transfers, Vaults}
  alias BabelSync.Transfers.{PendingUpload, Transfer}
  alias BabelSync.Vaults.Entry

  @read_bytes 1_000_000

  def download(conn, %{"token" => token}), do: serve_file(conn, token, false)

  def content(conn, _params) do
    case get_req_header(conn, "x-babel-transfer") do
      [token] -> serve_file(conn, token, true)
      _missing -> refuse(conn, :not_found, "This file is no longer available.")
    end
  end

  defp serve_file(conn, token, native?) do
    with {:ok, %Transfer{direction: :download} = transfer} <- Transfers.fetch(token, native?),
         {:ok, _scope} <- scope(transfer, :read),
         %Entry{deleted_at: nil} = entry <- Vaults.get_entry(transfer.entry_id),
         %Vaults.Vault{} = vault <- Vaults.get_vault(transfer.vault_id),
         :ok <- Agent.reachable(vault, entry.path) do
      path = if native?, do: transfer.path, else: entry.path

      conn =
        conn
        |> put_resp_header("content-disposition", disposition(path))
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")

      if native? do
        conn
        |> register_before_send(&put_resp_header(&1, "cache-control", "private, no-store"))
        |> snapshot(transfer)
      else
        deliver(conn, entry)
      end
    else
      _missing -> refuse(conn, :not_found, "This file is no longer available.")
    end
  end

  defp snapshot(conn, %Transfer{snapshot_text: text, path: path}) when is_binary(text) do
    conn |> put_resp_content_type(MIME.from_path(path)) |> send_resp(200, text)
  end

  defp snapshot(conn, %Transfer{blob_id: id, path: path}) do
    case id && BabelSync.Repo.get(Blobs.Blob, id) do
      nil -> refuse(conn, :not_found, "The file's bytes are missing.")
      blob -> BabelSyncWeb.BlobSender.send_blob(conn, blob, MIME.from_path(path))
    end
  end

  def stage(conn, _params) do
    case get_req_header(conn, "x-babel-transfer") do
      [token] -> receive_upload(conn, Transfers.claim_stage(token))
      _missing -> receive_upload(conn, :error)
    end
  end

  def upload(conn, %{"token" => token}), do: receive_upload(conn, Transfers.claim(token))

  defp receive_upload(conn, claimed) do
    with {:ok, transfer} <- claimed,
         {:ok, scope} <- scope(transfer, :write),
         :ok <- declared(conn, transfer.size) do
      receive_file(conn, scope, transfer)
    else
      :error ->
        refuse(conn, :not_found, "This link has expired, was used already, or was never valid.")

      {:error, :size} ->
        refuse(
          conn,
          :bad_request,
          "Send exactly the number of bytes the link was made for, with a Content-Length."
        )

      {:error, _denied} ->
        refuse(conn, :forbidden, "You no longer have write access to this vault.")
    end
  end

  defp receive_file(conn, scope, transfer) do
    staged = Path.join([BabelSync.data_dir(), "uploads", "transfer-" <> Ecto.UUID.generate()])
    File.mkdir_p!(Path.dirname(staged))

    try do
      case stream_body(conn, staged, transfer.size) do
        {:ok, conn} ->
          case store_file(transfer, scope, staged) do
            {:ok, result} ->
              json(conn, result)

            {:error, reason} ->
              refuse(
                conn,
                :unprocessable_entity,
                "The file was not stored: #{reason_text(reason)}"
              )
          end

        {:error, conn} ->
          refuse(conn, :bad_request, "The body did not match the size the link was made for.")
      end
    after
      File.rm(staged)
    end
  end

  defp store_file(%PendingUpload{} = upload, _scope, staged) do
    with :ok <- Transfers.stage(upload, staged), do: {:ok, %{bytes: upload.size}}
  end

  defp store_file(%Transfer{} = transfer, scope, staged) do
    with {:ok, placed} <-
           Agent.place_upload(scope, transfer.vault_id, transfer.path, staged, transfer.overwrite) do
      {:ok, %{path: placed.path, outcome: placed.outcome, bytes: transfer.size}}
    end
  end

  defp stream_body(conn, staged, size) do
    {:ok, file} = File.open(staged, [:write, :binary, :raw])

    try do
      copy(conn, file, 0, size)
    after
      File.close(file)
    end
  end

  defp copy(conn, file, received, size) do
    case read_body(conn, length: @read_bytes, read_length: @read_bytes) do
      {status, data, conn} when status in [:ok, :more] ->
        received = received + byte_size(data)

        if received > size do
          {:error, conn}
        else
          :ok = IO.binwrite(file, data)

          case status do
            :more -> copy(conn, file, received, size)
            :ok when received == size -> {:ok, conn}
            :ok -> {:error, conn}
          end
        end

      {:error, _reason} ->
        {:error, conn}
    end
  end

  defp declared(conn, size) do
    case get_req_header(conn, "content-length") do
      [length] -> if String.to_integer(length) == size, do: :ok, else: {:error, :size}
      _missing -> {:error, :size}
    end
  rescue
    ArgumentError -> {:error, :size}
  end

  defp scope(transfer, access) do
    with {:ok, scope} <- issuer(transfer),
         :ok <- Scope.authorize(scope, transfer.vault_id, access) do
      {:ok, scope}
    else
      :error -> {:error, :forbidden}
      error -> error
    end
  end

  defp issuer(%{grant_id: nil, user_id: user_id}) do
    case Accounts.get_user(user_id) do
      %Accounts.User{} = user -> {:ok, Scope.for_user(user)}
      nil -> :error
    end
  end

  defp issuer(%{grant_id: grant_id}), do: BabelSync.OAuth.scope_from_grant(grant_id)

  defp deliver(conn, %Entry{kind: :doc} = entry) do
    conn
    |> put_resp_content_type(MIME.from_path(entry.path))
    |> send_resp(200, Sync.text(entry.id))
  end

  defp deliver(conn, %Entry{kind: :blob, blob_hash: hash} = entry) when is_binary(hash) do
    case Blobs.get(entry.vault_id, hash) do
      nil -> refuse(conn, :not_found, "The file's bytes are missing.")
      blob -> BabelSyncWeb.BlobSender.send_blob(conn, blob, MIME.from_path(entry.path))
    end
  end

  defp deliver(conn, _entry), do: refuse(conn, :not_found, "That is a folder, not a file.")

  defp refuse(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end

  defp disposition(path) do
    name = Path.basename(path)
    plain = String.replace(name, ~r/[^\w .-]/u, "_")

    ~s(attachment; filename="#{plain}"; filename*=UTF-8''#{URI.encode(name, &URI.char_unreserved?/1)})
  end

  defp reason_text(:unguarded), do: "a file already exists there; ask for a link with overwrite"
  defp reason_text(:digest_mismatch), do: "the SHA-256 digest differs from the file offered"
  defp reason_text(:exists), do: "a file already exists there"
  defp reason_text(:not_text), do: "a note must be UTF-8 text"
  defp reason_text(:not_an_attachment), do: "a note or folder already exists there"
  defp reason_text(:off_limits), do: "the .obsidian folder is closed to agents in this vault"
  defp reason_text(:too_large), do: "it is larger than the server accepts"
  defp reason_text(:too_large_to_store), do: "it is larger than the server accepts"
  defp reason_text(:over_quota), do: "the vault has no room left for it"
  defp reason_text(:storage_unavailable), do: "storage is unavailable just now; try again later"
  defp reason_text(other) when is_atom(other), do: to_string(other)
  defp reason_text(_other), do: "storage is unavailable"
end
