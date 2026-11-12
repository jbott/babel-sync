defmodule BabelSync.Blobs.Store.Disk do
  @moduledoc false
  @behaviour BabelSync.Blobs.Store

  @read_bytes 256 * 1024

  @impl true
  def start_upload(_key) do
    ref = Ecto.UUID.generate()
    File.mkdir_p!(staging(ref))
    {:ok, ref}
  end

  @impl true
  def put_part(_key, ref, number, data) do
    target = part_path(ref, number)
    temporary = target <> ".tmp"

    with :ok <- File.mkdir_p(staging(ref)),
         :ok <- File.write(temporary, data, [:binary]),
         :ok <- File.rename(temporary, target) do
      {:ok, Integer.to_string(number)}
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  @impl true
  def finish_upload(key, ref, parts) do
    assemble(key, ref, parts)
  rescue
    error in [File.Error, MatchError] -> {:error, error}
  end

  defp assemble(key, ref, parts) do
    target = path(key)
    temporary = target <> "." <> ref <> ".tmp"
    File.mkdir_p!(Path.dirname(target))

    File.open!(temporary, [:write, :binary, :raw], fn out ->
      for {number, _tag} <- Enum.sort(parts) do
        ref
        |> part_path(number)
        |> File.stream!(@read_bytes)
        |> Enum.each(&(:ok = :file.write(out, &1)))
      end

      :ok = :file.sync(out)
    end)

    File.rename!(temporary, target)
    File.rm_rf!(staging(ref))
    :ok
  end

  @impl true
  def abort_upload(_key, ref) do
    File.rm_rf!(staging(ref))
    :ok
  end

  @impl true
  def stream(key, nil) do
    File.stream!(path(key), @read_bytes)
  end

  def stream(key, {first, last}) do
    Stream.resource(
      fn ->
        {:ok, file} = :file.open(path(key), [:read, :binary, :raw])
        {file, first}
      end,
      fn
        {file, at} when at > last ->
          {:halt, {file, at}}

        {file, at} ->
          case :file.pread(file, at, min(@read_bytes, last - at + 1)) do
            {:ok, data} -> {[data], {file, at + byte_size(data)}}
            :eof -> {:halt, {file, at}}
          end
      end,
      fn {file, _at} -> :file.close(file) end
    )
  end

  @impl true
  def delete(key) do
    File.rm(path(key))
    :ok
  end

  @spec path(String.t()) :: Path.t()
  def path(key), do: Path.join([BabelSync.data_dir(), "blobs", key])

  defp staging(ref), do: Path.join([BabelSync.data_dir(), "uploads", ref])
  defp part_path(ref, number), do: Path.join(staging(ref), Integer.to_string(number))
end
