defmodule BabelSync.AgentTest do
  use BabelSync.DataCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Agent, Sync, Vaults}

  setup do
    owner = user()
    vault = vault(owner, %{name: "Notes"})
    %{owner: owner, vault: vault, scope: Scope.for_user(owner)}
  end

  test "lists vaults with the caller's role", %{scope: scope, vault: vault} do
    assert Agent.list_vaults(scope) == [%{id: vault.id, name: "Notes", role: :owner}]
  end

  test "the vault can be omitted when there is only one, and named otherwise", ctx do
    assert {:ok, :created} = Agent.write_note(ctx.scope, nil, "a.md", "one")
    vault(ctx.owner, %{name: "Work"})

    assert {:error, :ambiguous_vault} = Agent.read_note(ctx.scope, nil, "a.md")
    assert {:ok, "one"} = Agent.read_note(ctx.scope, "Notes", "a.md")
    assert {:ok, "one"} = Agent.read_note(ctx.scope, ctx.vault.id, "a.md")
    assert {:error, :vault_not_found} = Agent.read_note(ctx.scope, "Nope", "a.md")
  end

  test "writes create, then update, notes", %{scope: scope} do
    assert {:ok, :created} = Agent.write_note(scope, nil, "Projects/plan.md", "# Plan\n")

    assert {:ok, :updated} =
             Agent.write_note(scope, nil, "Projects/plan.md", "# Plan\n\n- step\n")

    assert {:ok, "# Plan\n\n- step\n"} = Agent.read_note(scope, nil, "Projects/plan.md")

    assert {:ok, [%{path: "Projects/plan.md", kind: :doc}]} =
             Agent.list_files(scope, nil, "Projects")

    assert {:ok, []} = Agent.list_files(scope, nil, "Elsewhere")
  end

  test "an agent's rewrite merges with what a person is typing", %{scope: scope, vault: vault} do
    {:ok, :created} = Agent.write_note(scope, nil, "shared.md", "one\ntwo\n")
    note = Vaults.get_entry_by_path(vault.id, "shared.md")
    {doc, text} = client_doc(1)
    {:ok, update} = Sync.diff(note.id, Yex.encode_state_vector!(doc))
    :ok = Yex.apply_update(doc, update)

    Yex.Text.insert(text, 0, "typed by a person\n")
    {:ok, :updated} = Agent.write_note(scope, nil, "shared.md", "one\ntwo\nthree\n")
    {:ok, typed} = Yex.encode_state_as_update(doc, Sync.state_vector(note.id))
    :ok = Sync.apply_update(note.id, typed)

    assert {:ok, "typed by a person\none\ntwo\nthree\n"} =
             Agent.read_note(scope, nil, "shared.md")
  end

  test "edit replaces exactly one occurrence", %{scope: scope} do
    {:ok, :created} = Agent.write_note(scope, nil, "a.md", "alpha beta alpha")

    assert {:ok, :updated} = Agent.edit_note(scope, nil, "a.md", "beta", "gamma")
    assert {:ok, "alpha gamma alpha"} = Agent.read_note(scope, nil, "a.md")
    assert {:error, :ambiguous_match} = Agent.edit_note(scope, nil, "a.md", "alpha", "x")
    assert {:error, :no_match} = Agent.edit_note(scope, nil, "a.md", "missing", "x")
    assert {:error, :ambiguous_match} = Agent.edit_note(scope, nil, "a.md", "", "x")
    assert {:error, :not_found} = Agent.edit_note(scope, nil, "b.md", "a", "b")
  end

  test "append adds a line break only when needed and creates missing notes", %{scope: scope} do
    assert {:ok, :created} = Agent.append_note(scope, nil, "log.md", "first")
    assert {:ok, :updated} = Agent.append_note(scope, nil, "log.md", "second\n")
    assert {:ok, :updated} = Agent.append_note(scope, nil, "log.md", "third")

    assert {:ok, "first\nsecond\nthird"} = Agent.read_note(scope, nil, "log.md")
  end

  test "attachments cannot be read or written as notes", %{scope: scope, vault: vault} do
    entry(vault, "photo.png")

    assert {:error, :not_a_note} = Agent.read_note(scope, nil, "photo.png")
    assert {:error, :not_a_note} = Agent.write_note(scope, nil, "photo.png", "x")
    assert {:error, :not_a_note} = Agent.write_note(scope, nil, "new.png", "x")
    assert {:error, :invalid_path} = Agent.write_note(scope, nil, "../escape.md", "x")
  end

  test "moves and deletes files", %{scope: scope} do
    {:ok, :created} = Agent.write_note(scope, nil, "a.md", "x")
    {:ok, :created} = Agent.write_note(scope, nil, "b.md", "y")

    assert {:error, :exists} = Agent.move_file(scope, nil, "a.md", "b.md")
    assert {:ok, "Archive/a.md"} = Agent.move_file(scope, nil, "a.md", "Archive/a.md")
    assert {:ok, ["b.md"]} = Agent.delete_file(scope, nil, "b.md")
    assert {:error, :not_found} = Agent.delete_file(scope, nil, "b.md")
    assert {:ok, [%{path: "Archive/a.md"}]} = Agent.list_files(scope, nil)
  end

  test "search finds text and paths, case-insensitively, with context", %{scope: scope} do
    {:ok, :created} =
      Agent.write_note(scope, nil, "Recipes/soup.md", "Simmer the Lentils for 20 minutes.")

    {:ok, :created} = Agent.write_note(scope, nil, "lentil-notes.md", "nothing relevant")
    {:ok, :created} = Agent.write_note(scope, nil, "other.md", "100% unrelated_text")

    assert {:ok, results} = Agent.search_notes(scope, nil, "LENTIL")
    assert Enum.map(results, & &1.path) == ["Recipes/soup.md", "lentil-notes.md"]
    assert [%{matches: [snippet]} | _] = results
    assert snippet =~ "Lentils"

    assert {:ok, [%{path: "other.md"}]} = Agent.search_notes(scope, nil, "%")
    assert {:ok, [%{path: "other.md"}]} = Agent.search_notes(scope, nil, "100%")
    assert {:ok, [%{path: "other.md"}]} = Agent.search_notes(scope, nil, "unrelated_text")
    assert {:ok, []} = Agent.search_notes(scope, nil, "unrelatedXtext")
  end

  test "history lists versions that can be read back", %{scope: scope} do
    {:ok, :created} = Agent.write_note(scope, nil, "a.md", "v1")
    {:ok, :updated} = Agent.write_note(scope, nil, "a.md", "v2")

    assert {:ok, [%{version: _latest}, %{version: first}]} = Agent.history(scope, nil, "a.md")
    assert {:ok, "v1"} = Agent.read_version(scope, nil, "a.md", first)
    assert {:error, :not_found} = Agent.read_version(scope, nil, "a.md", -1)
  end

  test "roles and read-only credentials are enforced", ctx do
    {:ok, :created} = Agent.write_note(ctx.scope, nil, "a.md", "secret")
    viewer = user()
    {:ok, _} = Vaults.put_member(ctx.vault, viewer, :viewer)
    stranger = Scope.for_user(user())
    read_only = Scope.for_user(ctx.owner, read_only: true)

    assert {:ok, "secret"} = Agent.read_note(Scope.for_user(viewer), nil, "a.md")
    assert {:error, :forbidden} = Agent.write_note(Scope.for_user(viewer), nil, "a.md", "x")
    assert {:error, :forbidden} = Agent.delete_file(read_only, nil, "a.md")
    assert {:ok, "secret"} = Agent.read_note(read_only, nil, "a.md")
    assert {:error, :vault_not_found} = Agent.read_note(stranger, ctx.vault.id, "a.md")
    assert Agent.list_vaults(stranger) == []
    assert {:ok, "secret"} = Agent.read_note(ctx.scope, nil, "a.md")
  end
end
