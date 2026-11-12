defmodule BabelSync.BlobsTest do
  use BabelSync.DataCase, async: true

  import BabelSync.Fixtures

  alias BabelSync.Blobs

  @part 8 * 1024 * 1024

  setup do
    %{vault: vault()}
  end

  defp digest(data), do: :crypto.hash(:sha256, data)

  test "small content round-trips and is stored once", %{vault: vault} do
    assert {:ok, blob} = Blobs.put(vault.id, "hello attachment")
    assert {:ok, again} = Blobs.put(vault.id, "hello attachment")

    assert blob.id == again.id
    assert blob.size == 16
    assert blob.hash == Blobs.hash([digest("hello attachment")])
    assert Blobs.read(blob) == "hello attachment"
  end

  @tag :tmp_dir
  test "a file on disk is stored in parts and named like the same bytes in memory", %{
    vault: vault,
    tmp_dir: dir
  } do
    data = :crypto.strong_rand_bytes(2 * @part + 12_345)
    file = Path.join(dir, "big.bin")
    File.write!(file, data)

    assert {:ok, blob} = Blobs.put_file(vault.id, file)
    assert blob.hash == Blobs.hash_binary(data)
    assert blob.size == byte_size(data)
    assert Blobs.read(blob) == data
    assert {:ok, ^blob} = Blobs.put_file(vault.id, file)
  end

  test "empty content is a valid blob", %{vault: vault} do
    assert {:ok, blob} = Blobs.put(vault.id, "")
    assert Blobs.read(blob) == ""
  end

  test "the same content in two vaults is stored separately", %{vault: vault} do
    other = vault()
    {:ok, blob} = Blobs.put(vault.id, "shared bytes")

    assert Blobs.get(other.id, blob.hash) == nil
  end

  test "a multi-part upload resumes with only the missing parts", %{vault: vault} do
    first = :crypto.strong_rand_bytes(@part)
    second = :crypto.strong_rand_bytes(@part)
    third = :crypto.strong_rand_bytes(1234)
    hash = Blobs.hash([digest(first), digest(second), digest(third)])
    size = 2 * @part + 1234

    assert {:ok, upload, [1, 2, 3]} = Blobs.begin_upload(vault.id, %{hash: hash, size: size})
    assert :ok = Blobs.put_part(upload, 3, third)
    assert :ok = Blobs.put_part(upload, 1, first)
    assert {:error, {:missing, [2]}} = Blobs.complete_upload(upload)

    assert {:ok, resumed, [2]} = Blobs.begin_upload(vault.id, %{hash: hash, size: size})
    assert resumed.id == upload.id
    assert :ok = Blobs.put_part(resumed, 2, second)
    assert {:ok, blob} = Blobs.complete_upload(resumed)

    assert blob.size == size
    assert Blobs.read(blob) == first <> second <> third
    assert {:exists, _} = Blobs.begin_upload(vault.id, %{hash: hash, size: size})
    assert Blobs.get_upload(upload.id) == nil
  end

  test "a byte range can be read from the middle of a blob", %{vault: vault} do
    data = :crypto.strong_rand_bytes(@part + 1000)
    {:ok, blob} = Blobs.put(vault.id, data)

    range =
      blob |> Blobs.stream({@part - 10, @part + 9}) |> Enum.to_list() |> IO.iodata_to_binary()

    assert range == binary_part(data, @part - 10, 20)
  end

  test "parts of the wrong size or number are refused", %{vault: vault} do
    {:ok, upload, [1, 2]} =
      Blobs.begin_upload(vault.id, %{hash: String.duplicate("a", 64), size: @part + 1})

    assert {:error, :wrong_size} = Blobs.put_part(upload, 1, "short")
    assert {:error, :wrong_size} = Blobs.put_part(upload, 2, "xx")
    assert {:error, :invalid_part} = Blobs.put_part(upload, 3, "x")
    assert {:error, :invalid_part} = Blobs.put_part(upload, 0, "x")
  end

  test "content that does not match its claimed hash is discarded", %{vault: vault} do
    claimed = String.duplicate("b", 64)
    {:ok, upload, [1]} = Blobs.begin_upload(vault.id, %{hash: claimed, size: 4})
    :ok = Blobs.put_part(upload, 1, "evil")

    assert {:error, :hash_mismatch} = Blobs.complete_upload(upload)
    assert Blobs.get(vault.id, claimed) == nil
    assert Blobs.get_upload(upload.id) == nil
  end

  test "oversized and malformed uploads are refused up front", %{vault: vault} do
    hash = String.duplicate("c", 64)

    assert {:error, :too_large} =
             Blobs.begin_upload(vault.id, %{hash: hash, size: Blobs.max_size() + 1})

    assert {:error, :invalid} = Blobs.begin_upload(vault.id, %{hash: "../../etc/passwd", size: 1})
    assert {:error, :invalid} = Blobs.begin_upload(vault.id, %{hash: hash, size: -1})
  end
end
