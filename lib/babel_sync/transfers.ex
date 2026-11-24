defmodule BabelSync.Transfers do
  @moduledoc """
  Links that move a file's bytes outside an agent's tool calls, for any
  file: one too large to pass as base64, one that is not text, or a
  note an agent would rather fetch with curl.

  A link carries only a random handle. What it may do (who, which
  vault, which file, how many bytes) is kept on the server under a hash
  of the handle, so a link shown in a log or a transcript says nothing
  about the vault. Links last an hour, an upload link works once, and
  access to the vault is checked again when a link is used.

  Native MCP uploads are staged as blobs until an authorized retry claims
  the bytes. Native download targets pin the note text or attachment blob.
  """

  import Ecto.Query

  alias BabelSync.{Blobs, Repo}
  alias BabelSync.Transfers.{PendingUpload, Transfer}

  @lifetime 3600
  @receive_lease_seconds 300

  @spec upload_target(map()) :: map()
  def upload_target(%{} = upload) do
    {token, transfer} = issue(:upload, upload)

    %{
      url: url(token),
      method: "PUT",
      headers: %{"content-type" => "application/octet-stream"},
      credentials: "omit",
      expiresAt: DateTime.to_iso8601(DateTime.truncate(transfer.expires_at, :second))
    }
  end

  @spec download_target(map(), %{name: String.t(), mimeType: String.t(), size: non_neg_integer()}) ::
          map()
  def download_target(%{} = download, file) do
    native? = is_binary(download[:blob_id]) or is_binary(download[:snapshot_text])
    {token, transfer} = issue(:download, download, native?)

    destination =
      if native? do
        %{
          url: BabelSyncWeb.Endpoint.url() <> "/files/content",
          headers: %{"x-babel-transfer" => token}
        }
      else
        %{url: url(token)}
      end

    Map.merge(
      file,
      Map.merge(destination, %{
        credentials: "omit",
        expiresAt: DateTime.to_iso8601(DateTime.truncate(transfer.expires_at, :second))
      })
    )
  end

  @spec request_upload(map(), binary(), String.t(), binary() | nil) :: map()
  def request_upload(attrs, arguments_hash, file_id, expected_digest) do
    target = token()
    state = token()
    expires_at = DateTime.add(DateTime.utc_now(), @lifetime, :second)

    Repo.insert!(%PendingUpload{
      target_hash: digest(target),
      state_hash: digest(state),
      arguments_hash: arguments_hash,
      digest: expected_digest,
      user_id: attrs.user_id,
      grant_id: attrs.grant_id,
      vault_id: attrs.vault_id,
      size: attrs.size,
      expires_at: expires_at
    })

    %{
      "resultType" => "upload_required",
      "requestState" => state,
      "uploads" => [
        %{
          fileId: file_id,
          url: BabelSyncWeb.Endpoint.url() <> "/files/stage",
          method: "PUT",
          headers: %{"x-babel-transfer" => target, "content-type" => "application/octet-stream"},
          credentials: "omit",
          expiresAt: DateTime.to_iso8601(DateTime.truncate(expires_at, :second))
        }
      ]
    }
  end

  @spec claim_stage(String.t()) :: {:ok, PendingUpload.t()} | {:error, :receiving} | :error
  def claim_stage(token) do
    now = DateTime.utc_now()
    lease = DateTime.add(now, @receive_lease_seconds, :second)

    target = from u in pending(), where: u.target_hash == ^digest(token)

    available =
      from u in target, where: is_nil(u.receiving_until) or u.receiving_until <= ^now, select: u

    case Repo.update_all(available, set: [receiving_until: lease]) do
      {1, [upload]} -> {:ok, upload}
      _missing -> if Repo.exists?(target), do: {:error, :receiving}, else: :error
    end
  end

  @spec release_stage(PendingUpload.t()) :: :ok
  def release_stage(upload) do
    Repo.update_all(receiving(upload), set: [receiving_until: nil])
    :ok
  end

  defp receiving(upload) do
    from u in PendingUpload,
      where: u.id == ^upload.id and u.receiving_until == ^upload.receiving_until
  end

  @spec stage(PendingUpload.t(), Path.t()) :: :ok | {:error, term()}
  def stage(upload, path) do
    with :ok <- check_digest(upload.digest, path),
         {:ok, blob} <- Blobs.put_file(upload.vault_id, path),
         {1, _} <-
           Repo.update_all(
             from(u in receiving(upload),
               where: u.expires_at > ^DateTime.utc_now() and u.size == ^blob.size
             ),
             set: [blob_id: blob.id, target_hash: nil, receiving_until: nil]
           ) do
      :ok
    else
      {0, _} -> {:error, :invalid_size}
      error -> error
    end
  end

  defp check_digest(nil, _path), do: :ok

  defp check_digest(expected, path) do
    hash =
      path
      |> File.stream!(Blobs.part_size())
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    if hash == expected, do: :ok, else: {:error, :digest_mismatch}
  end

  @spec confirm_upload(String.t(), binary(), BabelSync.Accounts.Scope.t()) ::
          {:ok, Blobs.Blob.t()} | {:error, :invalid_state | :missing_upload}
  def confirm_upload(state, arguments_hash, scope) do
    query =
      from u in pending(),
        where: is_nil(u.consumed_at),
        where:
          u.state_hash == ^digest(state) and u.arguments_hash == ^arguments_hash and
            u.user_id == ^scope.user.id

    with %PendingUpload{grant_id: grant} = upload when grant == scope.grant_id <- Repo.one(query),
         %Blobs.Blob{size: size} = blob when size == upload.size <- staged_blob(upload),
         {1, _} <-
           Repo.update_all(from(u in query, where: u.blob_id == ^blob.id),
             set: [consumed_at: DateTime.utc_now()]
           ) do
      {:ok, blob}
    else
      :missing -> {:error, :missing_upload}
      _invalid -> {:error, :invalid_state}
    end
  end

  defp staged_blob(%PendingUpload{blob_id: nil}), do: :missing
  defp staged_blob(%PendingUpload{blob_id: id}), do: Repo.get(Blobs.Blob, id) || :missing

  defp pending do
    now = DateTime.utc_now()
    from u in PendingUpload, where: u.expires_at > ^now
  end

  @spec fetch(String.t(), boolean()) :: {:ok, Transfer.t()} | :error
  def fetch(token, native? \\ false) do
    now = DateTime.utc_now()

    case Repo.one(
           from t in Transfer,
             where: t.token_hash == ^transfer_hash(token, native?) and t.expires_at > ^now
         ) do
      %Transfer{} = transfer -> {:ok, transfer}
      nil -> :error
    end
  end

  @spec claim(String.t()) :: {:ok, Transfer.t()} | :error
  def claim(token) do
    now = DateTime.utc_now()

    query =
      from t in Transfer,
        where: t.token_hash == ^digest(token) and t.expires_at > ^now and t.direction == :upload,
        select: t

    case Repo.delete_all(query) do
      {1, [transfer]} -> {:ok, transfer}
      {0, _none} -> :error
    end
  end

  @spec prune(DateTime.t()) :: :ok
  def prune(now \\ DateTime.utc_now()) do
    Repo.delete_all(from u in PendingUpload, where: u.expires_at < ^now)
    Repo.delete_all(from t in Transfer, where: t.expires_at < ^now)
    :ok
  end

  defp issue(direction, attrs, native? \\ false) do
    token = token()

    transfer =
      Repo.insert!(%Transfer{
        token_hash: transfer_hash(token, native?),
        direction: direction,
        user_id: attrs.user_id,
        grant_id: attrs[:grant_id],
        vault_id: attrs.vault_id,
        entry_id: attrs[:entry_id],
        snapshot_text: attrs[:snapshot_text],
        blob_id: attrs[:blob_id],
        path: attrs[:path],
        size: attrs[:size],
        overwrite: attrs[:overwrite] || false,
        expires_at: DateTime.add(DateTime.utc_now(), @lifetime, :second)
      })

    {token, transfer}
  end

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp digest(token), do: :crypto.hash(:sha256, token)

  defp transfer_hash(token, true), do: digest([<<255>>, token])
  defp transfer_hash(token, false), do: digest(token)

  defp url(token), do: BabelSyncWeb.Endpoint.url() <> "/files/" <> token
end
