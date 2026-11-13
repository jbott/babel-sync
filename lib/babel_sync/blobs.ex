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

  @part_size 8 * 1024 * 1024

  @spec part_size() :: pos_integer()
  def part_size, do: @part_size

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

  @spec vault_quota() :: pos_integer() | nil
  def vault_quota, do: Application.fetch_env!(:babel_sync, __MODULE__)[:vault_quota]

  @spec usage(Ecto.UUID.t()) :: non_neg_integer()
  def usage(vault_id) do
    Repo.one(from b in Blob, where: b.vault_id == ^vault_id, select: sum(b.size)) || 0
  end

  defp room?(vault_id, size) do
    case vault_quota() do
      nil -> true
      quota -> usage(vault_id) + size <= quota
    end
  end

  @spec get(Ecto.UUID.t(), hash()) :: Blob.t() | nil
  def get(vault_id, hash), do: Repo.get_by(Blob, vault_id: vault_id, hash: hash)

  @spec begin_upload(Ecto.UUID.t(), %{hash: hash(), size: non_neg_integer()}) ::
          {:exists, Blob.t()}
          | {:ok, Upload.t(), missing :: [pos_integer()]}
          | {:error, :too_large | :over_quota | :invalid | term()}
  def begin_upload(vault_id, %{hash: hash, size: size}) do
    cond do
      not is_integer(size) or size < 0 or not (is_binary(hash) and hash =~ ~r/\A[0-9a-f]{64}\z/) ->
        {:error, :invalid}

      size > max_size() ->
        {:error, :too_large}

      blob = claim(vault_id, hash) ->
        {:exists, blob}

      upload = Repo.get_by(Upload, vault_id: vault_id, hash: hash) ->
        resume(upload, size)

      not room?(vault_id, size) ->
        {:error, :over_quota}

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
          touch(upload)

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
    touch(upload)
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

  @spec put_file(Ecto.UUID.t(), Path.t()) :: {:ok, Blob.t()} | {:error, term()}
  def put_file(vault_id, path) do
    size = File.stat!(path).size
    digests = path |> File.stream!(@part_size) |> Enum.map(&:crypto.hash(:sha256, &1))
    digests = if digests == [], do: [:crypto.hash(:sha256, <<>>)], else: digests

    case begin_upload(vault_id, %{hash: hash(digests), size: size}) do
      {:exists, blob} ->
        {:ok, blob}

      {:ok, upload, missing} ->
        {:ok, file} = :file.open(path, [:read, :binary, :raw])

        try do
          Enum.reduce_while(missing, :ok, fn number, :ok ->
            {:ok, data} = read_part(file, upload, number)

            case put_part(upload, number, data) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        after
          :file.close(file)
        end
        |> case do
          :ok -> complete_upload(upload)
          error -> error
        end

      error ->
        error
    end
  end

  defp read_part(file, upload, number) do
    case :file.pread(file, (number - 1) * upload.part_size, expected_size(upload, number)) do
      :eof -> {:ok, <<>>}
      result -> result
    end
  end

  @spec stream(Blob.t(), Store.range()) :: Enumerable.t()
  def stream(%Blob{} = blob, range \\ nil), do: Store.impl().stream(key(blob), range)

  @spec read(Blob.t()) :: binary()
  def read(%Blob{} = blob), do: blob |> stream() |> Enum.into(<<>>, & &1) |> IO.iodata_to_binary()

  @spec collect_garbage(DateTime.t()) :: non_neg_integer()
  def collect_garbage(uploaded_before) do
    current =
      from e in BabelSync.Vaults.Entry,
        where: e.vault_id == parent_as(:blob).vault_id and e.blob_hash == parent_as(:blob).hash

    historic =
      from v in BabelSync.Vaults.BlobVersion,
        join: e in BabelSync.Vaults.Entry,
        on: e.id == v.entry_id,
        where: e.vault_id == parent_as(:blob).vault_id and v.blob_hash == parent_as(:blob).hash

    unreferenced =
      from b in Blob,
        as: :blob,
        where: b.inserted_at < ^uploaded_before and not exists(current) and not exists(historic)

    unreferenced
    |> Repo.all()
    |> Enum.count(fn blob ->
      {:ok, collected?} =
        Repo.transact(fn ->
          with {1, _} <- Repo.delete_all(from b in unreferenced, where: b.id == ^blob.id),
               :ok <- Store.impl().delete(key(blob)) do
            {:ok, true}
          else
            {0, _} -> {:ok, false}
            {:error, reason} -> {:error, reason}
          end
        end)
        |> case do
          {:ok, collected?} -> {:ok, collected?}
          {:error, _kept_for_next_time} -> {:ok, false}
        end

      collected?
    end)
  end

  @spec stored(Ecto.UUID.t()) :: {[String.t()], [{String.t(), String.t()}]}
  def stored(vault_id) do
    blobs = Repo.all(from b in Blob, where: b.vault_id == ^vault_id, select: b.hash)
    uploads = Repo.all(from u in Upload, where: u.vault_id == ^vault_id)

    {Enum.map(blobs, &key(%{vault_id: vault_id, hash: &1})),
     Enum.map(uploads, &{key(&1), &1.store_ref})}
  end

  @spec discard({[String.t()], [{String.t(), String.t()}]}) :: :ok
  def discard({keys, uploads}) do
    Enum.each(uploads, fn {key, ref} -> Store.impl().abort_upload(key, ref) end)
    Enum.each(keys, fn key -> Store.impl().delete(key) end)
  end

  @spec abandon_stale_uploads(DateTime.t()) :: non_neg_integer()
  def abandon_stale_uploads(untouched_since) do
    stale = Repo.all(from u in Upload, where: u.updated_at < ^untouched_since)
    Enum.each(stale, &abandon/1)
    length(stale)
  end

  @spec local_path(Blob.t()) :: Path.t() | nil
  def local_path(%Blob{} = blob) do
    if Store.impl() == Store.Disk, do: Store.Disk.path(key(blob))
  end

  defp claim(vault_id, hash) do
    with %Blob{} = blob <- get(vault_id, hash),
         {1, _} <-
           Repo.update_all(from(b in Blob, where: b.id == ^blob.id),
             set: [inserted_at: DateTime.utc_now()]
           ) do
      blob
    else
      _gone -> nil
    end
  end

  defp touch(%Upload{id: id}) do
    Repo.update_all(from(u in Upload, where: u.id == ^id),
      set: [updated_at: DateTime.utc_now()]
    )
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
    if get(upload.vault_id, upload.hash) == nil, do: Store.impl().delete(key(upload))
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
