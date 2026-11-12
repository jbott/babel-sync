defmodule BabelSync.ZipTest do
  use ExUnit.Case, async: true

  alias BabelSync.Zip

  defp archive(entries), do: entries |> Zip.stream() |> Enum.to_list() |> IO.iodata_to_binary()

  test "files, folders and names beyond ASCII come back out" do
    bytes = :crypto.strong_rand_bytes(300_000)

    zipped =
      archive([
        {:folder, "Empty"},
        {"Notes/café.md", byte_size("# Café"), ["# Café"]},
        {"pic.bin", byte_size(bytes),
         [binary_part(bytes, 0, 1000), binary_part(bytes, 1000, 299_000)]}
      ])

    assert {:ok, files} = :zip.unzip(zipped, [:memory])

    assert Map.new(files, fn {name, data} -> {List.to_string(name), data} end) == %{
             "Empty/" => "",
             "Notes/café.md" => "# Café",
             "pic.bin" => bytes
           }
  end

  test "an empty archive is still an archive" do
    assert {:ok, []} = :zip.unzip(archive([]), [:memory])
  end

  test "a file shorter than it was said to be is refused rather than written wrong" do
    assert_raise ArgumentError, fn -> archive([{"short.md", 10, ["abc"]}]) end
  end
end
