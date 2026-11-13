defmodule BabelSync.ZipPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BabelSync.Zip

  defp name do
    gen all(
          parts <-
            list_of(
              string([?a..?z, ?A..?Z, ?0..?9, ?é, ?😀, ?\s, ?-], min_length: 1, max_length: 6),
              min_length: 1,
              max_length: 3
            )
        ) do
      Enum.join(parts, "/")
    end
  end

  defp file do
    gen all(
          name <- name(),
          data <- binary(max_length: 3000),
          cuts <- list_of(integer(0..3000), max_length: 3)
        ) do
      {name <> ".bin", data, chunks(data, cuts)}
    end
  end

  defp chunks(data, cuts) do
    cuts
    |> Enum.map(&min(&1, byte_size(data)))
    |> Enum.concat([0, byte_size(data)])
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] -> binary_part(data, from, to - from) end)
  end

  property "whatever goes in comes back out of the archive" do
    check all(files <- uniq_list_of(file(), uniq_fun: &elem(&1, 0), max_length: 6)) do
      zipped =
        files
        |> Enum.map(fn {name, data, chunks} -> {name, byte_size(data), chunks} end)
        |> Zip.stream()
        |> Enum.to_list()
        |> IO.iodata_to_binary()

      assert {:ok, unzipped} = :zip.unzip(zipped, [:memory])

      assert Map.new(unzipped, fn {name, data} -> {List.to_string(name), data} end) ==
               Map.new(files, fn {name, data, _} -> {name, data} end)
    end
  end
end
