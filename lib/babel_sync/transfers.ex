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

  The returned targets follow the upload and download targets of the
  draft `io.modelcontextprotocol/files` extension, so a client that
  speaks it can use them directly.
  """

  import Ecto.Query

  alias BabelSync.Repo
  alias BabelSync.Transfers.Transfer

  @lifetime 3600

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
    {token, transfer} = issue(:download, download)

    Map.merge(file, %{
      url: url(token),
      credentials: "omit",
      expiresAt: DateTime.to_iso8601(DateTime.truncate(transfer.expires_at, :second))
    })
  end

  @spec fetch(String.t()) :: {:ok, Transfer.t()} | :error
  def fetch(token) do
    now = DateTime.utc_now()

    case Repo.one(
           from t in Transfer, where: t.token_hash == ^digest(token) and t.expires_at > ^now
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
    Repo.delete_all(from t in Transfer, where: t.expires_at < ^now)
    :ok
  end

  defp issue(direction, attrs) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    transfer =
      Repo.insert!(%Transfer{
        token_hash: digest(token),
        direction: direction,
        user_id: attrs.user_id,
        grant_id: attrs[:grant_id],
        vault_id: attrs.vault_id,
        entry_id: attrs[:entry_id],
        path: attrs[:path],
        size: attrs[:size],
        overwrite: attrs[:overwrite] || false,
        expires_at: DateTime.add(DateTime.utc_now(), @lifetime, :second)
      })

    {token, transfer}
  end

  defp digest(token), do: :crypto.hash(:sha256, token)

  defp url(token), do: BabelSyncWeb.Endpoint.url() <> "/files/" <> token
end
