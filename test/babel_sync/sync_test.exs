defmodule BabelSync.SyncTest do
  use BabelSync.DataCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Sync
  alias BabelSync.Sync.DocServer

  setup do
    vault = vault()
    entry = entry(vault, "note.md")

    on_exit(fn -> stop(entry.id) end)
    %{vault: vault, entry: entry}
  end

  defp stop(entry_id) do
    case Registry.lookup(BabelSync.Sync.Registry, entry_id) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        DynamicSupervisor.terminate_child(BabelSync.Sync.Supervisor, pid)
        assert_receive {:DOWN, ^ref, _, _, _}

      [] ->
        :ok
    end
  end

  defp pull(entry_id, doc) do
    {:ok, update} = Sync.diff(entry_id, Yex.encode_state_vector!(doc))
    :ok = Yex.apply_update(doc, update)
  end

  defp push(entry_id, doc) do
    {:ok, update} = Yex.encode_state_as_update(doc, Sync.state_vector(entry_id))
    :ok = Sync.apply_update(entry_id, update)
  end

  test "a new note is empty", %{entry: entry} do
    assert Sync.text(entry.id) == ""
  end

  test "two clients editing concurrently converge", %{entry: entry} do
    :ok = Sync.replace_text(entry.id, "hello world")
    {alice, alice_text} = client_doc(1)
    {bob, bob_text} = client_doc(2)
    pull(entry.id, alice)
    pull(entry.id, bob)

    Yex.Text.insert(alice_text, 0, "A: ")
    Yex.Text.insert(bob_text, Yex.Text.length(bob_text), "!")
    push(entry.id, alice)
    push(entry.id, bob)
    pull(entry.id, alice)
    pull(entry.id, bob)

    assert Sync.text(entry.id) == "A: hello world!"
    assert Yex.Text.to_string(alice_text) == "A: hello world!"
    assert Yex.Text.to_string(bob_text) == "A: hello world!"
  end

  test "a whole-text replacement merges with a concurrent client edit", %{entry: entry} do
    :ok = Sync.replace_text(entry.id, "one\ntwo\nthree\n")
    {client, client_text} = client_doc(1)
    pull(entry.id, client)

    Yex.Text.insert(client_text, 0, "zero\n")
    :ok = Sync.replace_text(entry.id, "one\ntwo\nthree\nfour\n")
    push(entry.id, client)

    assert Sync.text(entry.id) == "zero\none\ntwo\nthree\nfour\n"
  end

  test "server-side edits around emoji and CJK stay intact for clients", %{entry: entry} do
    :ok = Sync.replace_text(entry.id, "a😀b 日本語 é")
    :ok = Sync.replace_text(entry.id, "a😀😃b 日本の語 é!")
    {client, client_text} = client_doc(1)
    pull(entry.id, client)

    assert Yex.Text.to_string(client_text) == "a😀😃b 日本の語 é!"
    assert Sync.text(entry.id) == "a😀😃b 日本の語 é!"
  end

  test "server-side inserts advance clocks in UTF-16 units like browser Yjs", %{entry: entry} do
    :ok = Sync.replace_text(entry.id, "😀")

    assert {:ok, vector} = Yex.decode_state_vector(Sync.state_vector(entry.id))
    assert Map.values(vector) == [2]
  end

  test "windows line endings are normalized", %{entry: entry} do
    :ok = Sync.replace_text(entry.id, "a\r\nb\r\n")

    assert Sync.text(entry.id) == "a\nb\n"
  end

  test "subscribers receive each update with its origin", %{entry: entry} do
    Sync.subscribe(entry.id)
    {client, client_text} = client_doc(1)
    Yex.Text.insert(client_text, 0, "hi")
    {:ok, update} = Yex.encode_state_as_update(client)
    :ok = Sync.apply_update(entry.id, update, origin: :me)

    entry_id = entry.id
    assert_receive {:doc_update, ^entry_id, ^update, :me}
  end

  test "malformed updates are rejected and change nothing", %{entry: entry} do
    :ok = Sync.replace_text(entry.id, "safe")

    assert {:error, _} = Sync.apply_update(entry.id, <<255, 255, 255>>)
    assert Sync.text(entry.id) == "safe"
  end

  test "content survives the document process stopping", %{entry: entry} do
    :ok = Sync.replace_text(entry.id, "durable")
    stop(entry.id)

    assert Sync.text(entry.id) == "durable"
  end

  test "compaction leaves alone updates the note's process never applied", %{entry: entry} do
    {client, client_text} = client_doc(1)
    Yex.Text.insert(client_text, 0, "first ")
    push(entry.id, client)

    {elsewhere, elsewhere_text} = client_doc(3)
    Yex.Text.insert(elsewhere_text, 0, "written by another node")
    foreign = BabelSync.Sync.Store.append(entry.id, Yex.encode_state_as_update!(elsewhere))

    for n <- 1..Application.fetch_env!(:babel_sync, BabelSync.Sync)[:compact_after] do
      Yex.Text.insert(client_text, Yex.Text.length(client_text), "#{n} ")
      push(entry.id, client)
    end

    {_state, updates} = BabelSync.Sync.Store.load(entry.id)
    assert foreign in Enum.map(updates, &elem(&1, 0))
  end

  test "compaction keeps content and lets old clients still sync", %{entry: entry} do
    {client, client_text} = client_doc(1)

    for n <- 1..(Application.fetch_env!(:babel_sync, BabelSync.Sync)[:compact_after] + 5) do
      Yex.Text.insert(client_text, Yex.Text.length(client_text), "#{n} ")
      push(entry.id, client)
    end

    {state, updates} = BabelSync.Sync.Store.load(entry.id)
    assert is_binary(state)
    assert length(updates) == 5

    stop(entry.id)
    {late, late_text} = client_doc(2)
    pull(entry.id, late)

    assert Yex.Text.to_string(late_text) == Yex.Text.to_string(client_text)
    assert Sync.text(entry.id) == Yex.Text.to_string(client_text)
  end

  test "flushing records a version and the entry's content hash once", %{entry: entry} do
    :ok = Sync.replace_text(entry.id, "v1")
    :ok = Sync.flush(entry.id)
    :ok = Sync.flush(entry.id)
    :ok = Sync.replace_text(entry.id, "v2")
    :ok = Sync.flush(entry.id)

    assert [%{content: "v2"}, %{content: "v1"} = first] = Sync.list_versions(entry.id)
    assert BabelSync.Vaults.get_entry(entry.id).content_hash == BabelSync.Sync.Store.hash("v2")
    assert BabelSync.Vaults.get_entry(entry.id).size == 2

    :ok = Sync.restore_version(entry.id, first.id)
    assert Sync.text(entry.id) == "v1"
    assert Sync.restore_version(entry.id, -1) == {:error, :not_found}
  end

  test "the document process stops when idle and saves a version", %{entry: entry} do
    :ok = Sync.replace_text(entry.id, "idle")
    [{pid, _}] = Registry.lookup(BabelSync.Sync.Registry, entry.id)
    ref = Process.monitor(pid)
    send(pid, :timeout)

    assert_receive {:DOWN, ^ref, _, _, :normal}
    assert [%{content: "idle"}] = Sync.list_versions(entry.id)
    assert DocServer.via(entry.id) |> GenServer.whereis() == nil
  end

  test "a note whose process is shut down is settled first", %{entry: entry} do
    :ok = Sync.replace_text(entry.id, "typed just before a restart")
    stop(entry.id)

    assert [%{content: "typed just before a restart"}] = Sync.list_versions(entry.id)

    assert BabelSync.Vaults.get_entry(entry.id).content_hash ==
             BabelSync.Sync.Store.hash("typed just before a restart")
  end

  test "a note whose process was killed unsettled is settled when next opened", %{entry: entry} do
    :ok = Sync.replace_text(entry.id, "typed just before a crash")
    [{pid, _}] = Registry.lookup(BabelSync.Sync.Registry, entry.id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, :killed}
    assert Sync.list_versions(entry.id) == []

    assert Sync.text(entry.id) == "typed just before a crash"
    :ok = Sync.flush(entry.id)

    assert [%{content: "typed just before a crash"}] = Sync.list_versions(entry.id)

    assert BabelSync.Vaults.get_entry(entry.id).content_hash ==
             BabelSync.Sync.Store.hash("typed just before a crash")
  end

  test "reading a settled note nobody has open does not bring it to life", %{entry: entry} do
    :ok = Sync.replace_text(entry.id, "at rest")
    stop(entry.id)

    assert Sync.text(entry.id) == "at rest"
    assert Sync.texts([entry.id]) == %{entry.id => "at rest"}
    refute Sync.live?(entry.id)
  end

  test "reading a note with an edit newer than its last version opens it", %{entry: entry} do
    :ok = Sync.replace_text(entry.id, "saved")
    :ok = Sync.flush(entry.id)
    :ok = Sync.replace_text(entry.id, "saved, then typed just before a crash")
    [{pid, _}] = Registry.lookup(BabelSync.Sync.Registry, entry.id)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, :killed}

    assert Sync.texts([entry.id]) == %{entry.id => "saved, then typed just before a crash"}
    assert Sync.live?(entry.id)
  end

  test "opening a settled or empty note saves nothing", %{entry: entry} do
    assert Sync.text(entry.id) == ""
    stop(entry.id)
    assert Sync.list_versions(entry.id) == []

    :ok = Sync.replace_text(entry.id, "once")
    stop(entry.id)
    assert Sync.text(entry.id) == "once"
    stop(entry.id)
    assert [%{content: "once"}] = Sync.list_versions(entry.id)
  end
end
