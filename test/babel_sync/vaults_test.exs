defmodule BabelSync.VaultsTest do
  use BabelSync.DataCase, async: true

  import BabelSync.Fixtures

  alias BabelSync.Vaults

  describe "access" do
    test "the creator owns the vault and others have no access" do
      owner = user()
      stranger = user()
      vault = vault(owner)

      assert Vaults.role(owner, vault.id) == :owner
      assert Vaults.authorize(owner, vault.id, :admin) == :ok
      assert Vaults.authorize(stranger, vault.id, :read) == {:error, :forbidden}
      assert Vaults.list_vaults(stranger) == []
    end

    test "roles limit what a member may do" do
      vault = vault()
      editor = user()
      viewer = user()
      {:ok, _} = Vaults.put_member(vault, editor, :editor)
      {:ok, _} = Vaults.put_member(vault, viewer, :viewer)

      assert Vaults.authorize(editor, vault.id, :write) == :ok
      assert Vaults.authorize(editor, vault.id, :admin) == {:error, :forbidden}
      assert Vaults.authorize(viewer, vault.id, :read) == :ok
      assert Vaults.authorize(viewer, vault.id, :write) == {:error, :forbidden}
      assert [%{id: id}] = Vaults.list_vaults(viewer)
      assert id == vault.id
    end

    test "changing a role replaces the old one and removal revokes access" do
      vault = vault()
      member = user()
      {:ok, _} = Vaults.put_member(vault, member, :viewer)
      {:ok, _} = Vaults.put_member(vault, member, :editor)

      assert Vaults.role(member, vault.id) == :editor
      assert :ok = Vaults.remove_member(vault, member)
      assert Vaults.role(member, vault.id) == nil
    end

    test "a user can own several vaults" do
      owner = user()
      vault(owner, %{name: "Work"})
      vault(owner, %{name: "Home"})

      assert ["Home", "Work"] = owner |> Vaults.list_vaults() |> Enum.map(& &1.name)
    end
  end

  describe "entries" do
    test "kind follows the extension and paths are normalized" do
      vault = vault()

      assert entry(vault, "/Daily\\2026-11-10.md").path == "Daily/2026-11-10.md"
      assert entry(vault, "note.md").kind == :doc
      assert entry(vault, "photo.PNG").kind == :blob
      assert entry(vault, ".obsidian/app.json").kind == :blob
    end

    test "paths that escape the vault are rejected" do
      vault = vault()

      assert {:error, changeset} = Vaults.create_entry(vault.id, %{path: "../secrets.md"})
      assert %{path: ["is not a valid vault path"]} = errors_on(changeset)
    end

    test "creating an existing path returns the entry already there" do
      vault = vault()
      first = entry(vault, "a.md")

      assert {:error, {:exists, existing}} = Vaults.create_entry(vault.id, %{path: "a.md"})
      assert existing.id == first.id
    end

    test "every change takes the next sequence number" do
      vault = vault()
      a = entry(vault, "a.md")
      b = entry(vault, "b.md")
      {:ok, [renamed]} = Vaults.rename_entry(a, "c.md")

      assert [a.seq, b.seq, renamed.seq] == [1, 2, 3]
      assert Vaults.changes_since(vault.id, 2) |> Enum.map(& &1.path) == ["c.md"]
    end

    test "renaming keeps the entry id and refuses to overwrite" do
      vault = vault()
      a = entry(vault, "a.md")
      entry(vault, "b.md")

      assert {:error, {:exists, _}} = Vaults.rename_entry(a, "b.md")
      assert {:ok, [renamed]} = Vaults.rename_entry(a, "sub/a.md")
      assert renamed.id == a.id
    end

    test "renaming a folder moves everything inside it" do
      vault = vault()
      folder = entry(vault, "old", %{kind: :folder})
      entry(vault, "old/a.md")
      entry(vault, "old/deep/b.md")
      entry(vault, "older.md")

      assert {:ok, moved} = Vaults.rename_entry(folder, "new")
      assert length(moved) == 3

      assert Vaults.list_entries(vault.id) |> Enum.map(& &1.path) ==
               ["new", "new/a.md", "new/deep/b.md", "older.md"]
    end

    test "a folder moved or deleted gives each entry inside its own sequence number" do
      vault = vault()
      {:ok, folder} = Vaults.create_entry(vault.id, %{path: "old", kind: :folder})
      for n <- 1..12, do: {:ok, _} = Vaults.create_entry(vault.id, %{path: "old/#{n}.md"})
      before = Vaults.get_vault(vault.id).seq

      {:ok, moved} = Vaults.rename_entry(folder, "new")

      assert moved |> Enum.map(& &1.seq) |> Enum.sort() ==
               Enum.to_list((before + 1)..(before + 13))

      assert Vaults.get_vault(vault.id).seq == before + 13

      {:ok, deleted} = Vaults.delete_entry(Vaults.get_entry(folder.id))

      assert deleted |> Enum.map(& &1.seq) |> Enum.sort() ==
               Enum.to_list((before + 14)..(before + 26))
    end

    test "deleting hides the entry, reports it as a change and frees the path" do
      vault = vault()
      a = entry(vault, "a.md")

      assert {:ok, [deleted]} = Vaults.delete_entry(a)
      assert deleted.deleted_at
      assert Vaults.list_entries(vault.id) == []
      assert [%{id: id}] = Vaults.changes_since(vault.id, a.seq)
      assert id == a.id
      assert entry(vault, "a.md").id != a.id
    end

    test "subscribers hear about changes" do
      vault = vault()
      Vaults.subscribe(vault.id)
      created = entry(vault, "a.md")

      assert_receive {:entry_changed, %{id: id}}
      assert id == created.id
    end

    test "a change made through a stale copy does not undo a rename" do
      vault = vault()
      stale = entry(vault, "draft.md")
      {:ok, [_moved]} = Vaults.rename_entry(stale, "Final/done.md")

      Vaults.subscribe(vault.id)
      assert {:ok, updated} = Vaults.update_entry(stale, %{content_hash: "abc", size: 3})
      assert updated.path == "Final/done.md"
      assert_receive {:entry_changed, %{path: "Final/done.md", content_hash: "abc"}}
    end

    test "a change made through a stale copy does not bring a deleted entry back" do
      vault = vault()
      stale = entry(vault, "junk.md")
      {:ok, [deleted]} = Vaults.delete_entry(stale)

      Vaults.subscribe(vault.id)
      assert {:error, :not_found} = Vaults.update_entry(stale, %{content_hash: "abc", size: 3})
      assert {:error, :not_found} = Vaults.rename_entry(stale, "kept.md")
      assert {:error, :not_found} = Vaults.delete_entry(stale)
      refute_receive {:entry_changed, _entry}, 50
      assert [%{seq: seq}] = Vaults.changes_since(vault.id, 0)
      assert seq == deleted.seq
    end
  end

  describe "names that differ only by case" do
    test "are refused for letters beyond ASCII too" do
      vault = vault()
      {:ok, _} = Vaults.create_entry(vault.id, %{path: "Ärger.md"})

      assert {:error, {:exists, %{path: "Ärger.md"}}} =
               Vaults.create_entry(vault.id, %{path: "ärger.md"})
    end

    test "a note restored next to a case variant of its name gets a free name" do
      vault = vault()
      {:ok, note} = Vaults.create_entry(vault.id, %{path: "Note.md"})
      {:ok, _} = Vaults.delete_entry(note)
      {:ok, _} = Vaults.create_entry(vault.id, %{path: "note.md"})

      assert {:ok, %{path: "Note (restored).md"}} = Vaults.restore_entry(note)
    end

    test "a folder cannot be renamed so that a child lands on a case variant" do
      vault = vault()
      {:ok, folder} = Vaults.create_entry(vault.id, %{path: "B", kind: :folder})
      {:ok, _} = Vaults.create_entry(vault.id, %{path: "B/x.md"})
      {:ok, _} = Vaults.create_entry(vault.id, %{path: "a/x.md"})

      assert {:error, {:exists, %{path: "a/x.md"}}} = Vaults.rename_entry(folder, "A")
    end

    test "a folder holds its children whatever their case" do
      vault = vault()
      {:ok, folder} = Vaults.create_entry(vault.id, %{path: "Notes", kind: :folder})
      {:ok, _} = Vaults.create_entry(vault.id, %{path: "notes/x.md"})

      assert {:error, :not_empty} = Vaults.delete_entry(folder, if_empty: true)
      assert {:ok, moved} = Vaults.rename_entry(folder, "Archive")
      assert moved |> Enum.map(& &1.path) |> Enum.sort() == ["Archive", "Archive/x.md"]
    end

    test "a name with characters LIKE treats specially only matches itself" do
      vault = vault()
      {:ok, folder} = Vaults.create_entry(vault.id, %{path: "a_b", kind: :folder})
      {:ok, _} = Vaults.create_entry(vault.id, %{path: "axb/x.md"})

      assert {:ok, [_folder]} = Vaults.delete_entry(folder, if_empty: true)
    end
  end
end
