defmodule BabelSyncWeb.VaultChannelTest do
  use BabelSyncWeb.ChannelCase, async: false

  alias BabelSync.{Blobs, Sync, Vaults}

  setup do
    owner = user()
    vault = vault(owner)
    %{owner: owner, vault: vault}
  end

  defp join_vault(user, vault, params \\ %{}, opts \\ []) do
    user |> connect_as(opts) |> subscribe_and_join("vault:" <> vault.id, params)
  end

  test "joining returns the live tree and the current sequence", %{owner: owner, vault: vault} do
    entry(vault, "a.md")
    {:ok, _} = Vaults.delete_entry(entry(vault, "gone.md"))

    assert {:ok, reply, _socket} = join_vault(owner, vault)
    assert reply.seq == 3
    assert reply.writable
    assert [%{path: "a.md", deleted: false}] = reply.entries
  end

  test "joining with a sequence returns what changed since, deletions included", ctx do
    kept = entry(ctx.vault, "a.md")
    {:ok, _} = Vaults.delete_entry(entry(ctx.vault, "gone.md"))

    assert {:ok, reply, _socket} = join_vault(ctx.owner, ctx.vault, %{"since" => kept.seq})
    assert [%{path: "gone.md", deleted: true}] = reply.entries
  end

  test "people outside the vault cannot join", %{vault: vault} do
    assert {:error, %{reason: "forbidden"}} = join_vault(user(), vault)
  end

  test "creating a note stores its text and tells other clients", %{owner: owner, vault: vault} do
    {:ok, _, creator} = join_vault(owner, vault)
    {:ok, _, _watcher} = join_vault(owner, vault)

    ref = push(creator, "create", %{"path" => "Daily/today.md", "text" => "# Today\r\n"})

    assert_reply ref, :ok, %{entry: %{id: id, kind: :doc, path: "Daily/today.md"}}
    assert_push "entry", %{id: ^id}
    assert Sync.text(id) == "# Today\n"
  end

  test "creating a path that exists returns the existing entry", %{owner: owner, vault: vault} do
    existing = entry(vault, "a.md")
    {:ok, _, socket} = join_vault(owner, vault)

    ref = push(socket, "create", %{"path" => "a.md", "text" => "other"})

    assert_reply ref, :error, %{reason: "exists", entry: %{id: id}}
    assert id == existing.id
  end

  test "an attachment must be uploaded before an entry can point at it", ctx do
    {:ok, blob} = Blobs.put(ctx.vault.id, "png bytes")
    {:ok, _, socket} = join_vault(ctx.owner, ctx.vault)

    missing =
      push(socket, "create", %{"path" => "x.png", "blob_hash" => String.duplicate("0", 64)})

    assert_reply missing, :error, %{reason: "unknown_blob"}

    ref = push(socket, "create", %{"path" => "x.png", "blob_hash" => blob.hash})
    assert_reply ref, :ok, %{entry: %{kind: :blob, size: 9, blob_hash: hash}}
    assert hash == blob.hash
  end

  test "replacing an attachment detects a concurrent replacement", ctx do
    {:ok, v1} = Blobs.put(ctx.vault.id, "one")
    {:ok, v2} = Blobs.put(ctx.vault.id, "two")
    {:ok, v3} = Blobs.put(ctx.vault.id, "three")
    file = entry(ctx.vault, "x.png", %{blob_hash: v1.hash})
    {:ok, _, socket} = join_vault(ctx.owner, ctx.vault)

    first =
      push(socket, "set_blob", %{"id" => file.id, "blob_hash" => v2.hash, "base_hash" => v1.hash})

    assert_reply first, :ok, %{entry: %{blob_hash: current}}
    assert current == v2.hash

    stale =
      push(socket, "set_blob", %{"id" => file.id, "blob_hash" => v3.hash, "base_hash" => v1.hash})

    assert_reply stale, :error, %{reason: "conflict", entry: %{blob_hash: ^current}}
  end

  test "rename and delete are broadcast", %{owner: owner, vault: vault} do
    note = entry(vault, "a.md")
    {:ok, _, socket} = join_vault(owner, vault)

    renamed = push(socket, "rename", %{"id" => note.id, "path" => "b.md"})
    assert_reply renamed, :ok, %{entries: [%{path: "b.md"}]}
    assert_push "entry", %{path: "b.md", deleted: false}

    deleted = push(socket, "delete", %{"id" => note.id})
    assert_reply deleted, :ok, %{entries: [%{deleted: true}]}
    assert_push "entry", %{deleted: true}
  end

  test "entries of another vault cannot be touched", %{owner: owner, vault: vault} do
    foreign = entry(vault(owner), "theirs.md")
    {:ok, _, socket} = join_vault(owner, vault)

    ref = push(socket, "delete", %{"id" => foreign.id})

    assert_reply ref, :error, %{reason: "not_found"}
    assert Vaults.get_entry(foreign.id).deleted_at == nil
  end

  test "viewers and read-only credentials can watch but not change", ctx do
    viewer = user()
    {:ok, _} = Vaults.put_member(ctx.vault, viewer, :viewer)

    {:ok, reply, as_viewer} = join_vault(viewer, ctx.vault)
    refute reply.writable
    assert_reply push(as_viewer, "create", %{"path" => "a.md"}), :error, %{reason: "forbidden"}

    {:ok, reply, read_only} = join_vault(ctx.owner, ctx.vault, %{}, read_only: true)
    refute reply.writable
    assert_reply push(read_only, "create", %{"path" => "a.md"}), :error, %{reason: "forbidden"}
    assert Vaults.list_entries(ctx.vault.id) == []
  end
end
