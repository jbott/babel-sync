defmodule BabelSync.Bases.IndexTest do
  use BabelSync.DataCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Bases.{Index, Note}
  alias BabelSync.{Repo, Sync, Vaults}

  setup do
    vault = vault()
    note = entry(vault, "Tasks/a.md")
    on_exit(fn -> stop(note.id) end)
    %{vault: vault, note: note}
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

  defp save(note, text) do
    :ok = Sync.replace_text(note.id, text)
    :ok = Sync.flush(note.id)
    stop(note.id)
    Vaults.get_entry(note.id)
  end

  defp read(entry), do: [entry] |> Index.notes() |> hd()

  test "a note is read once, kept with its hash, and used while the note is unchanged", %{
    note: note
  } do
    note = save(note, "---\nstatus: open\ntags: [work]\n---\nSee [[Plan]] #urgent")

    assert %Note{properties: %{"status" => "open"}, tags: ["work", "urgent"], links: ["Plan"]} =
             read(note)

    row = Repo.get!(Index, note.id)
    assert row.content_hash == note.content_hash

    planted = %{properties: %{"status" => "from the index"}, tags: [], links: []}
    row |> Ecto.Changeset.change(data: :erlang.term_to_binary(planted)) |> Repo.update!()
    assert read(note).properties == %{"status" => "from the index"}
  end

  test "a note saved since it was read is read again", %{note: note} do
    first = save(note, "---\nstatus: open\n---\n")
    assert read(first).properties == %{"status" => "open"}

    second = save(note, "---\nstatus: done\n---\n")
    refute second.content_hash == first.content_hash
    assert read(second).properties == %{"status" => "done"}
    assert Repo.get!(Index, note.id).content_hash == second.content_hash
  end

  test "a note open for editing is read from its live text", %{note: note} do
    saved = save(note, "---\nstatus: open\n---\n")
    assert read(saved).properties == %{"status" => "open"}

    :ok = Sync.replace_text(note.id, "---\nstatus: typing\n---\n")
    assert read(saved).properties == %{"status" => "typing"}
  end

  test "a note open for editing with nothing typed is not read again", %{note: note} do
    saved = save(note, "---\nstatus: open\n---\n")
    assert read(saved).properties == %{"status" => "open"}

    planted = %{properties: %{"status" => "from the index"}, tags: [], links: []}

    Index
    |> Repo.get!(note.id)
    |> Ecto.Changeset.change(data: :erlang.term_to_binary(planted))
    |> Repo.update!()

    :ok = Sync.flush(note.id)
    assert Sync.live?(note.id)
    assert read(saved).properties == %{"status" => "from the index"}
  end

  test "files that are not notes have no properties, and rows go with their note", %{
    vault: vault,
    note: note
  } do
    note = save(note, "---\nstatus: open\n---\n")
    picture = entry(vault, "Tasks/p.png", %{kind: :blob, size: 3})

    assert [%Note{properties: %{"status" => "open"}}, %Note{properties: %{}, size: 3}] =
             Index.notes([note, picture])

    _trashed = Vaults.delete_entry(note)
    :ok = Vaults.purge_entry(note)
    refute Repo.get(Index, note.id)
  end
end
