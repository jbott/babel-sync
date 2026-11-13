defmodule BabelSync.JanitorTest do
  use BabelSync.DataCase, async: false

  import BabelSync.Fixtures
  import Ecto.Query

  alias BabelSync.{Blobs, Janitor, Repo, Sync, Vaults}
  alias BabelSync.Sync.Store

  @day 86_400

  defp days_from_now(days), do: DateTime.add(DateTime.utc_now(), days * @day, :second)

  defp stored?(key) do
    _bytes = key |> Blobs.Store.impl().stream(nil) |> Enum.to_list()
    true
  rescue
    _missing -> false
  end

  defp attachment(vault, path, data) do
    {:ok, blob} = Blobs.put(vault.id, data)

    {:ok, entry} =
      Vaults.create_entry(vault.id, %{
        path: path,
        kind: :blob,
        blob_hash: blob.hash,
        size: blob.size
      })

    entry
  end

  defp replace(entry, data) do
    {:ok, blob} = Blobs.put(entry.vault_id, data)
    {:ok, entry} = Vaults.update_entry(entry, %{blob_hash: blob.hash, size: blob.size})
    entry
  end

  defp age(schema, id, field) do
    import Ecto.Query
    Repo.update_all(from(r in schema, where: r.id == ^id), set: [{field, days_from_now(-3)}])
  end

  describe "attachments recognised as text" do
    test "become notes with the same identity, text and history" do
      vault = vault()
      base = attachment(vault, "Places/Restaurants.base", "views:\r\n  - type: table\n")
      binary = attachment(vault, "broken.canvas", <<0, 255, 254>>)
      photo = attachment(vault, "photo.png", "not really a picture")

      :ok = Janitor.run()

      assert %{kind: :doc, blob_hash: nil} = promoted = Vaults.get_entry(base.id)
      assert promoted.seq > base.seq
      assert Sync.text(base.id) == "views:\n  - type: table\n"
      assert [%{blob_hash: hash}] = Vaults.list_blob_versions(base.id)
      assert hash == base.blob_hash
      assert %{kind: :blob} = Vaults.get_entry(binary.id)
      assert %{kind: :blob} = Vaults.get_entry(photo.id)

      :ok = Janitor.run()
      assert Vaults.get_entry(base.id).seq == promoted.seq
    end
  end

  describe "attachment history" do
    test "every replacement is kept and an old one can be restored" do
      vault = vault()
      entry = vault |> attachment("pic.png", "one") |> replace("two")

      assert [second, first] = Vaults.list_blob_versions(entry.id)
      assert {first.size, second.blob_hash} == {3, entry.blob_hash}

      assert {:ok, restored} = Vaults.restore_blob_version(entry, first.id)
      assert Blobs.read(Blobs.get(vault.id, restored.blob_hash)) == "one"
      assert length(Vaults.list_blob_versions(entry.id)) == 3
      assert {:error, :not_found} = Vaults.restore_blob_version(entry, -1)
    end
  end

  describe "trash" do
    test "a deleted note comes back with its text and identity" do
      vault = vault()
      note = entry(vault, "idea.md")
      :ok = Sync.replace_text(note.id, "keep me\n")
      {:ok, [deleted]} = Vaults.delete_entry(note)

      assert [%{id: id}] = Vaults.list_trash(vault.id)
      assert id == note.id

      Vaults.subscribe(vault.id)
      assert {:ok, restored} = Vaults.restore_entry(deleted)
      assert {restored.id, restored.path, restored.deleted_at} == {note.id, "idea.md", nil}
      assert restored.seq > deleted.seq
      assert_receive {:entry_changed, %{id: ^id, deleted_at: nil}}
      assert Sync.text(note.id) == "keep me\n"
      assert [] = Vaults.list_trash(vault.id)
      assert {:error, :not_found} = Vaults.restore_entry(deleted)
    end

    test "restoring next to a newer file of the same name keeps both" do
      vault = vault()
      {:ok, [deleted]} = vault |> entry("idea.md") |> Vaults.delete_entry()
      _newer = entry(vault, "idea.md")

      assert {:ok, %{path: "idea (restored).md"}} = Vaults.restore_entry(deleted)
    end

    test "purging removes the entry for good and tells returning devices to resync" do
      vault = vault()
      kept = entry(vault, "kept.md")
      {:ok, [deleted]} = vault |> entry("gone.md") |> Vaults.delete_entry()

      assert :ok = Vaults.purge_entry(kept)
      assert Vaults.get_entry(kept.id)

      assert :ok = Vaults.purge_entry(deleted)
      refute Vaults.get_entry(deleted.id)
      assert Vaults.get_vault(vault.id).purged_seq == deleted.seq
    end
  end

  describe "cleanup" do
    setup do
      previous = Application.fetch_env!(:babel_sync, Janitor)
      Application.put_env(:babel_sync, Janitor, Keyword.put(previous, :retention_days, 30))
      on_exit(fn -> Application.put_env(:babel_sync, Janitor, previous) end)
    end

    test "old versions go, but never the newest of a note" do
      vault = vault()
      busy = entry(vault, "busy.md")
      quiet = entry(vault, "quiet.md")
      for text <- ["a", "b"], do: Store.put_version(busy.id, text, {nil, nil})
      Store.put_version(quiet.id, "only", {nil, nil})

      assert :ok = Janitor.run(days_from_now(29))
      assert length(Store.list_versions(busy.id)) == 2

      assert :ok = Janitor.run(days_from_now(31))
      assert [%{content: "b"}] = Store.list_versions(busy.id)
      assert [%{content: "only"}] = Store.list_versions(quiet.id)
    end

    test "a note keeps only so many versions, however recent" do
      previous = Application.get_env(:babel_sync, Janitor)
      Application.put_env(:babel_sync, Janitor, Keyword.put(previous, :versions_per_note, 3))
      vault = vault()
      busy = entry(vault, "busy.md")
      quiet = entry(vault, "quiet.md")
      for text <- ~w(a b c d e), do: Store.put_version(busy.id, text, {nil, nil})
      for text <- ~w(x y z), do: Store.put_version(quiet.id, text, {nil, nil})

      assert :ok = Janitor.run()
      assert ~w(e d c) == Enum.map(Store.list_versions(busy.id), & &1.content)
      assert ~w(z y x) == Enum.map(Store.list_versions(quiet.id), & &1.content)
    end

    test "attachment bytes are deleted once no entry, trash or history refers to them" do
      vault = vault()
      entry = vault |> attachment("pic.png", "old bytes") |> replace("new bytes")
      [_new, old] = Vaults.list_blob_versions(entry.id)
      {:ok, orphan} = Blobs.put(vault.id, "never attached")

      assert :ok = Janitor.run(DateTime.utc_now())
      assert Blobs.get(vault.id, orphan.hash)

      assert :ok = Janitor.run(days_from_now(2))
      refute Blobs.get(vault.id, orphan.hash)
      assert Blobs.read(Blobs.get(vault.id, old.blob_hash)) == "old bytes"

      assert :ok = Janitor.run(days_from_now(31))
      refute Blobs.get(vault.id, old.blob_hash)
      assert Blobs.read(Blobs.get(vault.id, entry.blob_hash)) == "new bytes"
      assert [_current] = Vaults.list_blob_versions(entry.id)
    end

    test "the trash is emptied after the retention period, and its bytes with it" do
      vault = vault()
      doomed = attachment(vault, "doomed.bin", "doomed bytes")
      {:ok, [deleted]} = Vaults.delete_entry(doomed)

      assert :ok = Janitor.run(days_from_now(29))
      assert [_still_there] = Vaults.list_trash(vault.id)
      assert Blobs.get(vault.id, doomed.blob_hash)

      assert :ok = Janitor.run(days_from_now(31))
      assert [] = Vaults.list_trash(vault.id)
      refute Blobs.get(vault.id, doomed.blob_hash)
      assert Vaults.get_vault(vault.id).purged_seq == deleted.seq
    end

    test "an upload nobody finished is abandoned" do
      vault = vault()

      {:ok, upload, [1]} =
        Blobs.begin_upload(vault.id, %{hash: String.duplicate("ab", 32), size: 10})

      assert :ok = Janitor.run(DateTime.utc_now())
      assert Blobs.get_upload(upload.id)
      assert :ok = Janitor.run(days_from_now(2))
      refute Blobs.get_upload(upload.id)
    end

    test "bytes assembled for an upload that was never recorded go with it" do
      vault = vault()
      data = "assembled, then the server stopped"
      hash = Blobs.hash_binary(data)
      {:ok, upload, [1]} = Blobs.begin_upload(vault.id, %{hash: hash, size: byte_size(data)})
      :ok = Blobs.put_part(upload, 1, data)
      key = "vaults/#{vault.id}/#{hash}"
      [tag] = Repo.all(from p in Blobs.Part, where: p.upload_id == ^upload.id, select: p.tag)
      :ok = Blobs.Store.impl().finish_upload(key, upload.store_ref, [{1, tag}])
      assert stored?(key)

      assert :ok = Janitor.run(days_from_now(2))
      refute Blobs.get_upload(upload.id)
      refute stored?(key)
    end

    test "bytes a device has just been told it need not upload are kept" do
      vault = vault()
      {:ok, blob} = Blobs.put(vault.id, "about to be attached")
      age(Blobs.Blob, blob.id, :inserted_at)

      assert {:exists, _blob} =
               Blobs.begin_upload(vault.id, %{hash: blob.hash, size: blob.size})

      assert :ok = Janitor.run(DateTime.utc_now())
      assert Blobs.get(vault.id, blob.hash)
    end

    test "an upload that is still receiving parts is not abandoned" do
      vault = vault()
      data = "slow upload"

      {:ok, upload, [1]} =
        Blobs.begin_upload(vault.id, %{hash: Blobs.hash_binary(data), size: byte_size(data)})

      age(Blobs.Upload, upload.id, :updated_at)
      :ok = Blobs.put_part(upload, 1, data)

      assert :ok = Janitor.run(DateTime.utc_now())
      assert Blobs.get_upload(upload.id)
    end

    test "deleting a vault deletes its attachment bytes" do
      vault = vault()
      {:ok, blob} = Blobs.put(vault.id, "private bytes")
      assert Blobs.read(blob) == "private bytes"

      {:ok, _deleted} = Vaults.delete_vault(vault)

      gone? =
        try do
          Blobs.read(blob) != "private bytes"
        rescue
          _missing -> true
        end

      assert gone?
    end

    test "with retention off, history and trash are kept" do
      Application.put_env(:babel_sync, Janitor, retention_days: 0)
      vault = vault()
      note = entry(vault, "note.md")
      for text <- ["a", "b"], do: Store.put_version(note.id, text, {nil, nil})
      {:ok, _deleted} = vault |> entry("gone.md") |> Vaults.delete_entry()

      assert :ok = Janitor.run(days_from_now(4000))
      assert length(Store.list_versions(note.id)) == 2
      assert [_kept] = Vaults.list_trash(vault.id)
      assert Repo.aggregate(Vaults.Entry, :count) == 2
    end
  end

  describe "the process" do
    test "runs when its timer fires" do
      previous = Application.fetch_env!(:babel_sync, Janitor)

      Application.put_env(:babel_sync, Janitor,
        enabled: true,
        retention_days: 30,
        interval: 3_600_000
      )

      on_exit(fn -> Application.put_env(:babel_sync, Janitor, previous) end)

      vault = vault()

      {:ok, upload, [1]} =
        Blobs.begin_upload(vault.id, %{hash: String.duplicate("cd", 32), size: 10})

      Repo.update_all(Blobs.Upload, set: [updated_at: DateTime.add(DateTime.utc_now(), -3, :day)])

      pid = start_supervised!(Janitor)
      send(pid, :run)
      _ = :sys.get_state(pid)
      refute Blobs.get_upload(upload.id)
    end
  end
end
