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

    push(socket, "awareness", {:binary, <<1, 2, 3>>})

    assert_broadcast "awareness", {:binary, <<1, 2, 3>>}
    refute_push "awareness", _
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
    assert {:error, %{reason: "forbidden"}} = join_doc(ctx.owner, attachment, doc)
    assert {:error, %{reason: "forbidden"}} = join_doc(ctx.owner, ctx.note, doc)
  end
end
