defmodule BabelSyncWeb.DocChannelTest do
  use BabelSyncWeb.ChannelCase, async: false

  alias BabelSync.{Sync, Vaults}

  setup do
    owner = user()
    vault = vault(owner)
    note = entry(vault, "note.md")
    :ok = Sync.replace_text(note.id, "server text")
    %{owner: owner, vault: vault, note: note}
  end

  defp join_doc(user, note, doc, opts \\ []) do
    params = %{"sv" => Base.encode64(Yex.encode_state_vector!(doc))}
    user |> connect_as(opts) |> subscribe_and_join("doc:" <> note.id, params)
  end

  defp local_update(doc, reply) do
    {:ok, update} = Yex.encode_state_as_update(doc, Base.decode64!(reply.sv))
    update
  end

  test "an editor reads but cannot change a text file among the plugins", %{vault: vault} do
    editor = user()
    {:ok, _} = Vaults.put_member(vault, editor, :editor)
    readme = entry(vault, ".obsidian/plugins/calendar/README.md")
    :ok = Sync.replace_text(readme.id, "as shipped")
    {doc, text} = client_doc(7)

    assert {:ok, %{writable: false} = reply, socket} = join_doc(editor, readme, doc)
    :ok = Yex.apply_update(doc, Base.decode64!(reply.update))
    Yex.Text.insert(text, 0, "changed ")

    assert_reply push(socket, "update", {:binary, local_update(doc, reply)}), :error, %{
      reason: "forbidden"
    }

    assert Sync.text(readme.id) == "as shipped"
  end

  test "joining brings the client up to date", %{owner: owner, note: note} do
    {doc, text} = client_doc(1)

    assert {:ok, reply, _socket} = join_doc(owner, note, doc)
    :ok = Yex.apply_update(doc, Base.decode64!(reply.update))

    assert reply.writable
    assert Yex.Text.to_string(text) == "server text"
  end

  test "offline edits are merged on join and live edits reach other clients", ctx do
    {alice, alice_text} = client_doc(1)
    {bob, bob_text} = client_doc(2)
    {:ok, alice_reply, alice_socket} = join_doc(ctx.owner, ctx.note, alice)
    :ok = Yex.apply_update(alice, Base.decode64!(alice_reply.update))
    {:ok, bob_reply, _bob_socket} = join_doc(ctx.owner, ctx.note, bob)
    :ok = Yex.apply_update(bob, Base.decode64!(bob_reply.update))

    Yex.Text.insert(alice_text, 0, "alice: ")
    update = local_update(alice, alice_reply)
    ref = push(alice_socket, "update", {:binary, update})

    assert_reply ref, :ok
    assert_push "update", {:binary, ^update}
    :ok = Yex.apply_update(bob, update)
    assert Yex.Text.to_string(bob_text) == "alice: server text"
    assert Sync.text(ctx.note.id) == "alice: server text"
  end

  test "a client does not receive its own update back", ctx do
    {doc, text} = client_doc(1)
    {:ok, reply, socket} = join_doc(ctx.owner, ctx.note, doc)
    :ok = Yex.apply_update(doc, Base.decode64!(reply.update))
    Yex.Text.insert(text, 0, "x")

    ref = push(socket, "update", {:binary, local_update(doc, reply)})

    assert_reply ref, :ok
    refute_push "update", _
  end

  test "server-side changes are pushed to connected clients", ctx do
    {doc, text} = client_doc(1)
    {:ok, reply, _socket} = join_doc(ctx.owner, ctx.note, doc)
    :ok = Yex.apply_update(doc, Base.decode64!(reply.update))

    :ok = Sync.replace_text(ctx.note.id, "server text, edited by an agent")

    assert_push "update", {:binary, update}
    :ok = Yex.apply_update(doc, update)
    assert Yex.Text.to_string(text) == "server text, edited by an agent"
  end

  test "cursor state is relayed to others and not echoed", ctx do
    {doc, _} = client_doc(1)
    {:ok, _, socket} = join_doc(ctx.owner, ctx.note, doc)
    :ok = Sync.subscribe(ctx.note.id)

    push(socket, "awareness", {:binary, <<1, 2, 3>>})

    assert_receive {:awareness, <<1, 2, 3>>}
    refute_push "awareness", _
  end

  test "edits to a note that has been deleted are refused, not kept in the trash", ctx do
    {doc, text} = client_doc(1)
    {:ok, reply, socket} = join_doc(ctx.owner, ctx.note, doc)
    :ok = Yex.apply_update(doc, Base.decode64!(reply.update))
    {:ok, _deleted} = Vaults.delete_entry(ctx.note)
    Yex.Text.insert(text, 0, "typed after the delete ")

    assert_reply push(socket, "update", {:binary, local_update(doc, reply)}), :error, %{
      reason: "not_found"
    }

    assert_reply push(socket, "flush", %{}), :error, %{reason: "not_found"}
    assert Sync.text(ctx.note.id) == "server text"
  end

  test "a restored note takes edits again, and a deleted vault ends the channel", ctx do
    {doc, text} = client_doc(1)
    {:ok, reply, socket} = join_doc(ctx.owner, ctx.note, doc)
    :ok = Yex.apply_update(doc, Base.decode64!(reply.update))
    {:ok, [deleted]} = Vaults.delete_entry(ctx.note)
    {:ok, _restored} = Vaults.restore_entry(deleted)
    Yex.Text.insert(text, 0, "x")

    assert_reply push(socket, "update", {:binary, local_update(doc, reply)}), :ok

    ref = Process.monitor(socket.channel_pid)
    Process.unlink(socket.channel_pid)
    {:ok, _vault} = Vaults.delete_vault(ctx.vault)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
  end

  test "a client can ask for its edits to be announced to the vault now", ctx do
    {doc, text} = client_doc(1)
    {:ok, reply, socket} = join_doc(ctx.owner, ctx.note, doc)
    :ok = Yex.apply_update(doc, Base.decode64!(reply.update))
    Yex.Text.insert(text, 0, "x")
    assert_reply push(socket, "update", {:binary, local_update(doc, reply)}), :ok
    :ok = Vaults.subscribe(ctx.vault.id)

    assert_reply push(socket, "flush", %{}), :ok

    assert_receive {:entry_changed, %{content_hash: hash}}
    assert hash == BabelSync.Sync.Store.hash("xserver text")
  end

  test "viewers receive edits but cannot make them", ctx do
    viewer = user()
    {:ok, _} = Vaults.put_member(ctx.vault, viewer, :viewer)
    {doc, text} = client_doc(1)
    {:ok, reply, socket} = join_doc(viewer, ctx.note, doc)
    :ok = Yex.apply_update(doc, Base.decode64!(reply.update))
    Yex.Text.insert(text, 0, "vandalism ")

    ref = push(socket, "update", {:binary, local_update(doc, reply)})

    refute reply.writable
    assert_reply ref, :error, %{reason: "forbidden"}
    assert Sync.text(ctx.note.id) == "server text"
  end

  test "garbage updates are rejected", ctx do
    {doc, _} = client_doc(1)
    {:ok, _, socket} = join_doc(ctx.owner, ctx.note, doc)

    ref = push(socket, "update", {:binary, <<255, 255>>})

    assert_reply ref, :error, %{reason: "invalid"}
    assert Sync.text(ctx.note.id) == "server text"
  end

  test "strangers, attachments and deleted notes cannot be joined", ctx do
    {doc, _} = client_doc(1)
    attachment = entry(ctx.vault, "x.png")
    {:ok, _} = Vaults.delete_entry(ctx.note)

    assert {:error, %{reason: "forbidden"}} = join_doc(user(), ctx.note, doc)
    assert {:error, %{reason: "not_a_note"}} = join_doc(ctx.owner, attachment, doc)
    assert {:error, %{reason: "not_found"}} = join_doc(ctx.owner, ctx.note, doc)
  end

  test "viewers cannot ask for a note to be settled, and unknown requests are refused", ctx do
    viewer = user()
    {:ok, _} = Vaults.put_member(ctx.vault, viewer, :viewer)
    {doc, _text} = client_doc(1)
    {:ok, _reply, socket} = join_doc(viewer, ctx.note, doc)

    assert_reply push(socket, "flush", %{}), :error, %{reason: "forbidden"}
    assert_reply push(socket, "nonsense", %{}), :error, %{reason: "bad_request"}
  end

  test "a join without a state vector receives the whole note, a broken one is refused", ctx do
    assert {:ok, reply, _socket} =
             ctx.owner |> connect_as() |> subscribe_and_join("doc:" <> ctx.note.id, %{})

    {doc, text} = client_doc(2)
    :ok = Yex.apply_update(doc, Base.decode64!(reply.update))
    assert Yex.Text.to_string(text) == "server text"

    for bad <- ["not base64!", 42] do
      assert {:error, _reason} =
               ctx.owner
               |> connect_as()
               |> subscribe_and_join("doc:" <> ctx.note.id, %{"sv" => bad})
    end
  end
end
