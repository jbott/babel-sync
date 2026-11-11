defmodule BabelSync.Blobs do
  @moduledoc """
  Attachments and every other file that is not mergeable text.

  A blob is uploaded in fixed-size parts and named by the SHA-256 of its
  parts' SHA-256 digests. That name can be checked from the per-part
  digests alone, so a large upload is verified without reading it back
  from storage, and an interrupted upload resumes with only the parts
  that are missing.
  """

  import Ecto.Query

  alias BabelSync.Blobs.{Blob, Part, Store, Upload}
  alias BabelSync.Repo

  @type hash :: String.t()

  @spec part_size() :: pos_integer()
  def part_size, do: Application.fetch_env!(:babel_sync, __MODULE__)[:part_size]

  @spec max_size() :: pos_integer()
  def max_size, do: Application.fetch_env!(:babel_sync, __MODULE__)[:max_size]

  @spec hash([binary()]) :: hash()
  def hash(part_digests) do
    :crypto.hash(:sha256, part_digests) |> Base.encode16(case: :lower)
  end

  @spec hash_binary(binary()) :: hash()
  def hash_binary(data) do
    data |> split() |> Enum.map(&:crypto.hash(:sha256, &1)) |> hash()
  end

  @spec get(Ecto.UUID.t(), hash()) :: Blob.t() | nil
  def get(vault_id, hash), do: Repo.get_by(Blob, vault_id: vault_id, hash: hash)

  @spec begin_upload(Ecto.UUID.t(), %{hash: hash(), size: non_neg_integer()}) ::
          {:exists, Blob.t()}
          | {:ok, Upload.t(), missing :: [pos_integer()]}
          | {:error, :too_large | :invalid | term()}
  def begin_upload(vault_id, %{hash: hash, size: size}) do
    cond do
      not is_integer(size) or size < 0 or not (is_binary(hash) and hash =~ ~r/\A[0-9a-f]{64}\z/) ->
        {:error, :invalid}

      size > max_size() ->
        {:error, :too_large}

      blob = get(vault_id, hash) ->
        {:exists, blob}

      upload = Repo.get_by(Upload, vault_id: vault_id, hash: hash) ->
        resume(upload, size)

      true ->
        start(vault_id, hash, size)
    end
  end

  @spec get_upload(Ecto.UUID.t()) :: Upload.t() | nil
  def get_upload(id), do: Repo.get(Upload, id)

  @spec put_part(Upload.t(), pos_integer(), binary()) ::
          :ok | {:error, :invalid_part | :wrong_size | term()}
  def put_part(%Upload{} = upload, number, data) do
    cond do
      not is_integer(number) or number < 1 or number > part_count(upload) ->
        {:error, :invalid_part}

      byte_size(data) != expected_size(upload, number) ->
        {:error, :wrong_size}

      true ->
        with {:ok, tag} <- Store.impl().put_part(key(upload), upload.store_ref, number, data) do
          Repo.insert!(
            %Part{
              upload_id: upload.id,
              number: number,
              hash: Base.encode16(:crypto.hash(:sha256, data), case: :lower),
              size: byte_size(data),
              tag: tag
            },
            on_conflict: {:replace, [:hash, :size, :tag]},
            conflict_target: [:upload_id, :number]
          )

          :ok
        end
    end
  end

  @spec complete_upload(Upload.t()) ::
          {:ok, Blob.t()} | {:error, {:missing, [pos_integer()]} | :hash_mismatch | term()}
  def complete_upload(%Upload{} = upload) do
    parts = parts(upload)
    missing = missing(upload, parts)
    digests = Enum.map(parts, &Base.decode16!(&1.hash, case: :lower))

    cond do
      missing != [] ->
        {:error, {:missing, missing}}

      hash(digests) != upload.hash ->
        abandon(upload)
        {:error, :hash_mismatch}

      true ->
        tags = Enum.map(parts, &{&1.number, &1.tag})

        with :ok <- Store.impl().finish_upload(key(upload), upload.store_ref, tags) do
          blob =
            Repo.insert!(
              %Blob{
                vault_id: upload.vault_id,
                hash: upload.hash,
                size: upload.size,
                inserted_at: DateTime.utc_now()
              },
              on_conflict: :nothing,
              conflict_target: [:vault_id, :hash]
            )

          Repo.delete!(upload)
          {:ok, get(upload.vault_id, upload.hash) || blob}
        end
    end
  end

  @spec put(Ecto.UUID.t(), binary()) :: {:ok, Blob.t()} | {:error, term()}
  def put(vault_id, data) do
    case begin_upload(vault_id, %{hash: hash_binary(data), size: byte_size(data)}) do
      {:exists, blob} ->
        {:ok, blob}

      {:ok, upload, missing} ->
        chunks = data |> split() |> Enum.with_index(1) |> Map.new(fn {chunk, n} -> {n, chunk} end)

        Enum.reduce_while(missing, :ok, fn number, :ok ->
          case put_part(upload, number, Map.fetch!(chunks, number)) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
        |> case do
          :ok -> complete_upload(upload)
          error -> error
        end

      error ->
        error
    end
  end

  @spec stream(Blob.t(), Store.range()) :: Enumerable.t()
  def stream(%Blob{} = blob, range \\ nil), do: Store.impl().stream(key(blob), range)

  @spec read(Blob.t()) :: binary()
  def read(%Blob{} = blob), do: blob |> stream() |> Enum.into(<<>>, & &1) |> IO.iodata_to_binary()

  @spec local_path(Blob.t()) :: Path.t() | nil
  def local_path(%Blob{} = blob) do
    if Store.impl() == Store.Disk, do: Store.Disk.path(key(blob))
  end

  defp start(vault_id, hash, size) do
    key = key(%{vault_id: vault_id, hash: hash})

    with {:ok, ref} <- Store.impl().start_upload(key) do
      upload =
        Repo.insert!(%Upload{
          vault_id: vault_id,
          hash: hash,
          size: size,
          part_size: part_size(),
          store_ref: ref
        })

      {:ok, upload, missing(upload, [])}
    end
  end

  defp resume(%Upload{size: size} = upload, size),
    do: {:ok, upload, missing(upload, parts(upload))}

  defp resume(%Upload{} = upload, size) do
    abandon(upload)
    start(upload.vault_id, upload.hash, size)
  end

  defp abandon(upload) do
    Store.impl().abort_upload(key(upload), upload.store_ref)
    Repo.delete!(upload)
  end

  defp parts(upload) do
    Repo.all(from p in Part, where: p.upload_id == ^upload.id, order_by: p.number)
  end

  defp missing(upload, parts) do
    Enum.to_list(1..part_count(upload)//1) -- Enum.map(parts, & &1.number)
  end

  defp part_count(%Upload{size: 0}), do: 1
  defp part_count(%Upload{size: size, part_size: part_size}), do: ceil(size / part_size)

  defp expected_size(%Upload{} = upload, number) do
    if number == part_count(upload),
      do: upload.size - (number - 1) * upload.part_size,
      else: upload.part_size
  end

  defp split(<<>>), do: [<<>>]

  defp split(data) do
    size = part_size()

    for offset <- 0..(byte_size(data) - 1)//size,
        do: binary_part(data, offset, min(size, byte_size(data) - offset))
  end

  defp key(%{vault_id: vault_id, hash: hash}), do: "vaults/#{vault_id}/#{hash}"
end
