defmodule BabelSync.AgentTest do
  use BabelSync.DataCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Accounts.Scope
  alias BabelSync.Agent.Text
  alias BabelSync.{Agent, Blobs, Sync, Vaults}

  @pixel Base.decode64!(
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
         )

  setup do
    owner = user()
    vault = vault(owner, %{name: "Notes"})
    %{owner: owner, vault: vault, scope: Scope.for_user(owner)}
  end

  defp write(scope, path, content) do
    {:ok, %{outcome: :created}} = Agent.write_file(scope, nil, path, content)
    :ok
  end

  defp read(scope, path, opts \\ []) do
    {:ok, %{text: text}} = Agent.read_file(scope, nil, path, opts)
    text
  end

  test "lists vaults with the caller's role", %{scope: scope, vault: vault} do
    assert Agent.list_vaults(scope) == [%{id: vault.id, name: "Notes", role: :owner}]
  end

  test "the vault can be omitted when there is only one, and named otherwise", ctx do
    write(ctx.scope, "a.md", "one")
    vault(ctx.owner, %{name: "Work"})

    assert {:error, :ambiguous_vault} = Agent.read_file(ctx.scope, nil, "a.md")
    assert {:ok, %{text: "one"}} = Agent.read_file(ctx.scope, "Notes", "a.md")
    assert {:ok, %{text: "one"}} = Agent.read_file(ctx.scope, ctx.vault.id, "a.md")
    assert {:error, :vault_not_found} = Agent.read_file(ctx.scope, "Nope", "a.md")
  end

  describe "the .obsidian folder" do
    setup %{vault: vault} do
      entry(vault, ".obsidian/plugins/sample/main.js")
      entry(vault, ".obsidian/app.json")
      entry(vault, "note.md")
      :ok
    end

    test "is invisible to an agent", %{scope: scope} do
      assert {:ok, [%{path: "note.md"}]} = Agent.list_directory(scope, nil)
      assert {:ok, ["note.md"]} = Agent.find_files(scope, nil, "**")
      assert {:ok, %{changes: [%{path: "note.md"}]}} = Agent.list_changes(scope, nil)
      assert {:error, :off_limits} = Agent.list_directory(scope, nil, ".obsidian")
      assert {:error, :off_limits} = Agent.read_file(scope, nil, ".obsidian/app.json")
      assert {:error, :off_limits} = Agent.read_file(scope, nil, "/.Obsidian/app.json")
    end

    test "cannot be written, moved into, moved out of or deleted", %{scope: scope, vault: vault} do
      plugin = ".obsidian/plugins/sample/main.js"

      assert {:error, :off_limits} = Agent.write_file(scope, nil, ".obsidian/x.md", "x")
      assert {:error, :off_limits} = Agent.append_file(scope, nil, ".OBSIDIAN/x.md", "x")
      assert {:error, :off_limits} = Agent.create_directory(scope, nil, ".obsidian/plugins/evil")
      assert {:error, :off_limits} = Agent.move_file(scope, nil, "note.md", plugin)
      assert {:error, :off_limits} = Agent.move_file(scope, nil, "note.md", ".obsidian")
      assert {:error, :off_limits} = Agent.move_file(scope, nil, plugin, "main.js")
      assert {:error, :off_limits} = Agent.delete_file(scope, nil, plugin)
      assert {:error, :off_limits} = Agent.delete_file(scope, nil, ".obsidian")

      {:ok, _deleted} = Vaults.delete_entry(Vaults.get_entry_by_path(vault.id, plugin))
      assert {:ok, []} = Agent.list_trash(scope, nil)
      assert {:error, :off_limits} = Agent.restore_file(scope, nil, plugin)
      assert Vaults.get_entry_by_path(vault.id, ".obsidian/app.json")
    end

    test "is an ordinary folder once the vault opens it to agents", %{scope: scope, vault: vault} do
      {:ok, _vault} = Vaults.update_vault(vault, %{agents_see_config: true})

      assert {:ok, [%{path: ".obsidian/"}, %{path: "note.md"}]} = Agent.list_directory(scope, nil)
      assert {:ok, %{outcome: :created}} = Agent.write_file(scope, nil, ".obsidian/x.md", "x")
      assert {:ok, [".obsidian/x.md"]} = Agent.delete_file(scope, nil, ".obsidian/x.md")
    end
  end

  describe "looking around" do
    setup %{scope: scope, vault: vault} do
      write(scope, "top.md", "x")
      write(scope, "Projects/plan.md", "12345")
      write(scope, "Projects/Deep/more.md", "x")
      write(scope, "Projects/Deep/er/most.md", "x")
      entry(vault, "Projects/pic.png")
      :ok
    end

    test "a folder lists its files and its sub-folders with their file counts", %{scope: scope} do
      assert {:ok, top} = Agent.list_directory(scope, nil)

      assert [
               %{path: "Projects/", kind: :folder, files: 4},
               %{path: "top.md", kind: :note, bytes: 1}
             ] = top

      assert {:ok, projects} = Agent.list_directory(scope, nil, "/Projects/")

      assert [
               %{path: "Projects/Deep/", kind: :folder, files: 2},
               %{path: "Projects/pic.png", kind: :attachment},
               %{path: "Projects/plan.md", kind: :note, bytes: 5, modified: %DateTime{}}
             ] = projects
    end

    test "depth descends into sub-folders", %{scope: scope} do
      assert {:ok, listed} = Agent.list_directory(scope, nil, nil, 2)

      assert Enum.map(listed, & &1.path) == [
               "Projects/",
               "Projects/Deep/",
               "Projects/pic.png",
               "Projects/plan.md",
               "top.md"
             ]

      assert {:ok, everything} = Agent.list_directory(scope, nil, "", 9)
      assert "Projects/Deep/er/most.md" in Enum.map(everything, & &1.path)
    end

    test "empty folders, files and missing paths are told apart", %{scope: scope} do
      assert {:ok, "Empty"} = Agent.create_directory(scope, nil, "Empty")
      assert {:ok, []} = Agent.list_directory(scope, nil, "Empty")
      assert {:ok, top} = Agent.list_directory(scope, nil)
      assert %{path: "Empty/", kind: :folder, files: 0} = hd(top)

      assert {:error, :not_a_folder} = Agent.list_directory(scope, nil, "top.md")
      assert {:error, :not_found} = Agent.list_directory(scope, nil, "Nowhere")
    end

    test "files are found by path pattern", %{scope: scope} do
      assert {:ok, ["Projects/pic.png"]} = Agent.find_files(scope, nil, "*.png")

      assert {:ok, ["Projects/Deep/er/most.md", "Projects/Deep/more.md"]} =
               Agent.find_files(scope, nil, "projects/deep/**")

      assert {:ok, ["Projects/plan.md"]} = Agent.find_files(scope, nil, "Projects/*.md")
      assert {:ok, []} = Agent.find_files(scope, nil, "*.pdf")
      assert {:error, :invalid_pattern} = Agent.find_files(scope, nil, "{a")
    end
  end

  test "a reply stops at 256 KiB, even inside one long line", %{scope: scope} do
    long = String.duplicate("é", 200_000)
    write(scope, "long.md", "short\n" <> long <> "\nend")

    assert {:ok, %{first: 1, last: 1, cut: false}} = Agent.read_file(scope, nil, "long.md")

    assert {:ok, %{first: 2, last: 2, cut: true, text: text}} =
             Agent.read_file(scope, nil, "long.md", offset: 2)

    assert byte_size(text) <= 256 * 1024
    assert String.valid?(text)
  end

  test "a search that runs too long is stopped", %{scope: scope} do
    Application.put_env(:babel_sync, Agent, search_ms: 0)
    on_exit(fn -> Application.delete_env(:babel_sync, Agent) end)
    write(scope, "slow.md", String.duplicate("a", 5000) <> "!")

    assert {:error, :search_timeout} =
             Agent.search_files(scope, nil, "(a+)+b", regex: true)
  end

  describe "searching" do
    setup %{scope: scope} do
      write(scope, "Recipes/soup.md", "# Soup\nSimmer the Lentils for 20 minutes.\nServe.")
      write(scope, "lentil-notes.md", "nothing relevant")
      write(scope, "other.md", "100% unrelated_text\ncost: 42 EUR")
      :ok
    end

    test "finds text case-insensitively and reports line numbers", %{scope: scope} do
      assert {:ok, [%{path: "Recipes/soup.md", matches: [match]}]} =
               Agent.search_files(scope, nil, "LENTIL")

      assert %{line: 2, text: "Simmer the Lentils for 20 minutes.", match: true} = match
      assert {:ok, []} = Agent.search_files(scope, nil, "LENTIL", case_sensitive: true)
    end

    test "treats the query as plain text unless told it is a pattern", %{scope: scope} do
      assert {:ok, [%{path: "other.md"}]} = Agent.search_files(scope, nil, "100%")
      assert {:ok, [%{path: "other.md"}]} = Agent.search_files(scope, nil, "unrelated_text")
      assert {:ok, []} = Agent.search_files(scope, nil, "unrelated.text")
      assert {:ok, []} = Agent.search_files(scope, nil, "back\\slash")

      assert {:ok, [%{path: "other.md", matches: [%{line: 2}]}]} =
               Agent.search_files(scope, nil, "cost: \\d+ EUR", regex: true)

      assert {:error, :invalid_pattern} = Agent.search_files(scope, nil, "(", regex: true)
      assert {:error, :invalid_pattern} = Agent.search_files(scope, nil, "")
    end

    test "can be narrowed to a folder and widened with context", %{scope: scope} do
      write(scope, "Journal/day.md", "ate lentils")

      assert {:ok, [%{path: "Journal/day.md"}]} =
               Agent.search_files(scope, nil, "lentils", glob: "Journal/**")

      assert {:ok, [%{matches: lines}]} =
               Agent.search_files(scope, nil, "simmer", context: 1)

      assert Enum.map(lines, &{&1.line, &1.match}) == [{1, false}, {2, true}, {3, false}]
    end

    test "sees what was typed a moment ago and what was saved long ago", %{
      scope: scope,
      vault: vault
    } do
      note = Vaults.get_entry_by_path(vault.id, "other.md")
      {:ok, _before, _after} = Sync.rewrite_text(note.id, &{:ok, &1 <> "\njust typed"})
      assert {:ok, [%{path: "other.md"}]} = Agent.search_files(scope, nil, "just typed")

      idle = Vaults.get_entry_by_path(vault.id, "lentil-notes.md")
      [{server, _}] = Registry.lookup(BabelSync.Sync.Registry, idle.id)
      ref = Process.monitor(server)
      GenServer.stop(server)
      assert_receive {:DOWN, ^ref, :process, ^server, :normal}
      refute Sync.live?(idle.id)

      assert {:ok, [%{path: "lentil-notes.md"}]} = Agent.search_files(scope, nil, "relevant")
      refute Sync.live?(idle.id)
    end
  end

  describe "reading" do
    test "returns the text, its line range and its rev", %{scope: scope} do
      write(scope, "a.md", "one\ntwo\nthree\nfour\n")

      assert {:ok, %{kind: :note, path: "a.md", first: 1, last: 4, total: 4, rev: rev} = whole} =
               Agent.read_file(scope, nil, "a.md")

      assert whole.text == "one\ntwo\nthree\nfour\n"
      assert rev == Text.rev(whole.text)

      assert {:ok, %{text: "two\nthree", first: 2, last: 3, total: 4, rev: ^rev}} =
               Agent.read_file(scope, nil, "a.md", offset: 2, limit: 2)

      assert {:ok, %{text: "", first: 0, total: 4}} =
               Agent.read_file(scope, nil, "a.md", offset: 40)
    end

    test "outlines a note without its text", %{scope: scope} do
      write(scope, "a.md", "---\nstatus: open\n---\n# Title\n\n## Part\ntext\n")

      assert {:ok, outline} = Agent.outline(scope, nil, "a.md")

      assert %{
               path: "a.md",
               lines: 7,
               properties: ["status"],
               headings: [%{line: 4, level: 1, title: "Title"}, %{line: 6, level: 2}]
             } = outline

      assert outline.rev == Text.rev(read(scope, "a.md"))
    end

    test "shows an image attachment and describes other attachments", %{
      scope: scope,
      vault: vault
    } do
      {:ok, blob} = Blobs.put(vault.id, @pixel)
      entry(vault, "pixel.png", %{blob_hash: blob.hash, size: blob.size})
      entry(vault, "paper.pdf", %{size: 9})
      {:ok, "Folder"} = Agent.create_directory(scope, nil, "Folder")

      assert {:ok, %{kind: :attachment, type: "image/png", bytes: 70, image: @pixel}} =
               Agent.read_file(scope, nil, "pixel.png")

      assert {:ok, %{kind: :attachment, type: "application/pdf", image: nil}} =
               Agent.read_file(scope, nil, "paper.pdf")

      assert {:error, :not_a_note} = Agent.read_file(scope, nil, "Folder")
      assert {:error, :not_a_note} = Agent.outline(scope, nil, "pixel.png")
      assert {:error, :not_found} = Agent.read_file(scope, nil, "missing.md")
    end
  end

  describe "writing" do
    test "creates a note and reports what it wrote", %{scope: scope} do
      assert {:ok, %{outcome: :created, path: "Projects/plan.md", lines: 1, rev: rev} = written} =
               Agent.write_file(scope, nil, "Projects/plan.md", "# Plan\r\n")

      assert written.changed == "     1\t# Plan"
      assert rev == Text.rev("# Plan\n")
      assert read(scope, "Projects/plan.md") == "# Plan\n"
    end

    test "replaces an existing note only when told to or when the rev still holds", %{
      scope: scope
    } do
      {:ok, %{rev: first}} = Agent.write_file(scope, nil, "a.md", "v1")

      assert {:error, :unguarded} = Agent.write_file(scope, nil, "a.md", "careless")
      assert read(scope, "a.md") == "v1"

      assert {:ok, %{outcome: :updated, rev: second}} =
               Agent.write_file(scope, nil, "a.md", "v2", if_rev: first)

      assert {:error, {:stale, ^second}} =
               Agent.write_file(scope, nil, "a.md", "late", if_rev: first)

      assert read(scope, "a.md") == "v2"

      assert {:ok, %{outcome: :updated}} =
               Agent.write_file(scope, nil, "a.md", "v3", overwrite: true)

      assert read(scope, "a.md") == "v3"
    end

    test "a guarded replace is refused once a person has typed", %{scope: scope, vault: vault} do
      {:ok, %{rev: rev}} = Agent.write_file(scope, nil, "shared.md", "one\ntwo\n")
      note = Vaults.get_entry_by_path(vault.id, "shared.md")
      {:ok, _before, _after} = Sync.rewrite_text(note.id, &{:ok, "typed by a person\n" <> &1})

      assert {:error, {:stale, _now}} =
               Agent.write_file(scope, nil, "shared.md", "one\ntwo\nthree\n", if_rev: rev)

      assert read(scope, "shared.md") == "typed by a person\none\ntwo\n"
    end

    test "an unguarded replace still merges with what a person is typing", %{
      scope: scope,
      vault: vault
    } do
      write(scope, "shared.md", "one\ntwo\n")
      note = Vaults.get_entry_by_path(vault.id, "shared.md")
      {doc, text} = client_doc(1)
      {:ok, update} = Sync.diff(note.id, Yex.encode_state_vector!(doc))
      :ok = Yex.apply_update(doc, update)

      Yex.Text.insert(text, 0, "typed by a person\n")

      {:ok, %{outcome: :updated}} =
        Agent.write_file(scope, nil, "shared.md", "one\ntwo\nthree\n", overwrite: true)

      {:ok, typed} = Yex.encode_state_as_update(doc, Sync.state_vector(note.id))
      :ok = Sync.apply_update(note.id, typed)

      assert read(scope, "shared.md") == "typed by a person\none\ntwo\nthree\n"
    end

    test "only notes can be written, and only at valid paths", %{scope: scope, vault: vault} do
      entry(vault, "photo.png")

      assert {:error, :not_a_note} =
               Agent.write_file(scope, nil, "photo.png", "x", overwrite: true)

      assert {:error, :not_a_note} = Agent.write_file(scope, nil, "new.png", "x")
      assert {:error, :invalid_path} = Agent.write_file(scope, nil, "../escape.md", "x")
    end
  end

  describe "editing" do
    test "replaces exact passages and shows the changed lines", %{scope: scope} do
      write(scope, "a.md", "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\n")

      assert {:ok, %{outcome: :updated, lines: 6, changed: changed, rev: rev}} =
               Agent.edit_file(scope, nil, "a.md", [%{old_text: "delta", new_text: "DELTA"}])

      assert changed ==
               "     2\tbeta\n     3\tgamma\n     4\tDELTA\n     5\tepsilon\n     6\tzeta"

      assert rev == Text.rev(read(scope, "a.md"))
    end

    test "several edits apply together or not at all", %{scope: scope} do
      write(scope, "a.md", "alpha beta alpha")

      assert {:error, {:no_match, 2}} =
               Agent.edit_file(scope, nil, "a.md", [
                 %{old_text: "beta", new_text: "gamma"},
                 %{old_text: "missing", new_text: "x"}
               ])

      assert read(scope, "a.md") == "alpha beta alpha"

      assert {:ok, _written} =
               Agent.edit_file(scope, nil, "a.md", [
                 %{old_text: "beta", new_text: "gamma"},
                 %{old_text: "alpha", new_text: "A", replace_all: true}
               ])

      assert read(scope, "a.md") == "A gamma A"

      assert {:error, {:ambiguous_match, 1}} =
               Agent.edit_file(scope, nil, "a.md", [%{old_text: "A", new_text: "x"}])

      assert {:error, {:ambiguous_match, 1}} =
               Agent.edit_file(scope, nil, "a.md", [%{old_text: "", new_text: "x"}])

      assert {:error, :not_found} =
               Agent.edit_file(scope, nil, "b.md", [%{old_text: "a", new_text: "b"}])
    end

    test "an edit can be tied to a rev", %{scope: scope} do
      {:ok, %{rev: rev}} = Agent.write_file(scope, nil, "a.md", "one")
      edit = [%{old_text: "one", new_text: "two"}]

      assert {:error, {:stale, ^rev}} =
               Agent.edit_file(scope, nil, "a.md", edit, if_rev: "00000000")

      assert {:ok, _written} = Agent.edit_file(scope, nil, "a.md", edit, if_rev: rev)
      assert read(scope, "a.md") == "two"
    end

    test "append adds a line break only when needed and creates missing notes", %{scope: scope} do
      assert {:ok, %{outcome: :created}} = Agent.append_file(scope, nil, "log.md", "first")
      assert {:ok, %{outcome: :updated}} = Agent.append_file(scope, nil, "log.md", "second\n")

      assert {:ok, %{outcome: :updated, changed: changed}} =
               Agent.append_file(scope, nil, "log.md", "third")

      assert read(scope, "log.md") == "first\nsecond\nthird"
      assert changed =~ "     3\tthird"
    end

    test "append can target the section under a heading", %{scope: scope} do
      write(scope, "day.md", "# Day\n\n## Tasks\n- one\n\n## Notes\nnone\n")

      assert {:ok, %{changed: changed}} =
               Agent.append_file(scope, nil, "day.md", "- two", heading: "Tasks")

      assert changed =~ "     5\t- two"
      assert read(scope, "day.md") == "# Day\n\n## Tasks\n- one\n- two\n\n## Notes\nnone\n"
      assert {:error, :no_heading} = Agent.append_file(scope, nil, "day.md", "x", heading: "Nope")
      assert {:error, :not_found} = Agent.append_file(scope, nil, "new.md", "x", heading: "Tasks")
    end

    test "an edit or append is worked out from the text as it is when applied", %{
      scope: scope,
      vault: vault
    } do
      write(scope, "busy.md", "alpha\nomega\n")
      note = Vaults.get_entry_by_path(vault.id, "busy.md")

      typing =
        Task.async(fn ->
          for n <- 1..200 do
            {:ok, _before, _after} = Sync.rewrite_text(note.id, &{:ok, &1 <> "typed #{n}\n"})
          end
        end)

      for n <- 1..50 do
        {:ok, %{outcome: :updated}} = Agent.append_file(scope, nil, "busy.md", "appended #{n}\n")
      end

      {:ok, _written} =
        Agent.edit_file(scope, nil, "busy.md", [%{old_text: "alpha", new_text: "ALPHA"}])

      Task.await(typing)

      lines = scope |> read("busy.md") |> String.split("\n", trim: true)
      assert "ALPHA" in lines
      assert Enum.count(lines, &String.starts_with?(&1, "typed ")) == 200
      assert Enum.count(lines, &String.starts_with?(&1, "appended ")) == 50
    end
  end

  describe "moving, deleting and restoring" do
    test "the vault itself can be neither deleted nor moved", %{scope: scope} do
      write(scope, "a.md", "x")
      write(scope, "Notes/b.md", "y")

      for whole <- ["", "/", "//", "\\"] do
        assert {:error, :invalid_path} = Agent.delete_file(scope, nil, whole)
        assert {:error, :invalid_path} = Agent.move_file(scope, nil, whole, "Elsewhere")
      end

      assert {:ok, ["Notes/b.md", "a.md"]} = Agent.find_files(scope, nil, "**")
    end

    test "moves and deletes single files", %{scope: scope} do
      write(scope, "a.md", "x")
      write(scope, "b.md", "y")

      assert {:error, :exists} = Agent.move_file(scope, nil, "a.md", "b.md")
      assert {:ok, "Archive/a.md"} = Agent.move_file(scope, nil, "a.md", "Archive/a.md")
      assert {:ok, ["b.md"]} = Agent.delete_file(scope, nil, "b.md")
      assert {:error, :not_found} = Agent.delete_file(scope, nil, "b.md")
      assert {:ok, ["Archive/a.md"]} = Agent.find_files(scope, nil, "**")
      assert {:error, :not_found} = Agent.move_file(scope, nil, "missing.md", "b.md")
      assert {:error, :invalid_path} = Agent.move_file(scope, nil, "Archive/a.md", "../b.md")
    end

    test "a folder moves and is deleted with everything in it", %{scope: scope} do
      write(scope, "Work/plan.md", "plan")
      write(scope, "Work/Deep/more.md", "more")
      {:ok, "Work/Empty"} = Agent.create_directory(scope, nil, "Work/Empty")
      write(scope, "Workshop.md", "not in the folder")

      assert {:ok, "Done/Work"} = Agent.move_file(scope, nil, "Work", "Done/Work")

      assert {:ok, ["Done/Work/Deep/more.md", "Done/Work/plan.md", "Workshop.md"]} =
               Agent.find_files(scope, nil, "**")

      assert read(scope, "Done/Work/plan.md") == "plan"
      assert {:ok, deleted} = Agent.delete_file(scope, nil, "Done")
      assert "Done/Work/Deep/more.md" in deleted and "Done/Work/plan.md" in deleted
      assert {:ok, ["Workshop.md"]} = Agent.find_files(scope, nil, "**")
    end

    test "folders are created once and never over a file", %{scope: scope} do
      write(scope, "a.md", "x")

      assert {:ok, "New/Folder"} = Agent.create_directory(scope, nil, "New/Folder/")
      assert {:ok, "New/Folder"} = Agent.create_directory(scope, nil, "New/Folder")
      assert {:error, :exists} = Agent.create_directory(scope, nil, "a.md")
      assert {:error, :invalid_path} = Agent.create_directory(scope, nil, "../out")
    end

    test "a deleted file is listed in the trash and can be restored", %{scope: scope} do
      write(scope, "a.md", "keep me")
      {:ok, ["a.md"]} = Agent.delete_file(scope, nil, "a.md")

      assert {:ok, [%{path: "a.md", kind: :note, deleted_at: %DateTime{}}]} =
               Agent.list_trash(scope, nil)

      assert {:ok, "a.md"} = Agent.restore_file(scope, nil, "a.md")
      assert read(scope, "a.md") == "keep me"
      assert {:ok, []} = Agent.list_trash(scope, nil)
      assert {:error, :not_found} = Agent.restore_file(scope, nil, "a.md")
    end

    test "history lists versions that can be read back and restored", %{scope: scope} do
      write(scope, "a.md", "v1")
      {:ok, _written} = Agent.write_file(scope, nil, "a.md", "v2", overwrite: true)

      assert {:ok, %{versions: [%{version: _latest}, %{version: first}], older: 0}} =
               Agent.history(scope, nil, "a.md")

      assert read(scope, "a.md", version: first) == "v1"
      assert {:error, :not_found} = Agent.read_file(scope, nil, "a.md", version: -1)

      assert {:ok, %{outcome: :updated, changed: "     1\tv1"}} =
               Agent.restore_version(scope, nil, "a.md", first)

      assert read(scope, "a.md") == "v1"
      assert {:error, :not_found} = Agent.restore_version(scope, nil, "a.md", 0)
    end

    test "changes since a cursor are listed oldest first", %{scope: scope} do
      write(scope, "a.md", "x")

      assert {:ok, %{cursor: cursor, changes: [%{path: "a.md", change: :written}]}} =
               Agent.list_changes(scope, nil)

      assert {:ok, %{cursor: ^cursor, changes: []}} = Agent.list_changes(scope, nil, cursor)

      write(scope, "b.md", "y")
      {:ok, ["a.md"]} = Agent.delete_file(scope, nil, "a.md")

      assert {:ok, %{cursor: later, changes: changes}} = Agent.list_changes(scope, nil, cursor)
      assert later > cursor

      assert [%{path: "b.md", change: :written, kind: :note}, %{path: "a.md", change: :deleted}] =
               changes
    end
  end

  test "roles and read-only credentials are enforced", ctx do
    write(ctx.scope, "a.md", "secret")
    viewer = user()
    {:ok, _} = Vaults.put_member(ctx.vault, viewer, :viewer)
    viewer = Scope.for_user(viewer)
    stranger = Scope.for_user(user())
    read_only = Scope.for_user(ctx.owner, read_only: true)
    edit = [%{old_text: "secret", new_text: "x"}]

    assert read(viewer, "a.md") == "secret"
    assert read(read_only, "a.md") == "secret"
    assert {:ok, [_match]} = Agent.search_files(read_only, nil, "secret")
    assert {:ok, [_file]} = Agent.list_directory(read_only, nil)
    assert {:ok, %{changes: [_change]}} = Agent.list_changes(read_only, nil)

    assert {:error, :forbidden} = Agent.write_file(viewer, nil, "a.md", "x", overwrite: true)
    assert {:error, :forbidden} = Agent.write_file(read_only, nil, "new.md", "x")
    assert {:error, :forbidden} = Agent.edit_file(read_only, nil, "a.md", edit)
    assert {:error, :forbidden} = Agent.append_file(read_only, nil, "a.md", "x")
    assert {:error, :forbidden} = Agent.create_directory(read_only, nil, "Folder")
    assert {:error, :forbidden} = Agent.move_file(read_only, nil, "a.md", "b.md")
    assert {:error, :forbidden} = Agent.delete_file(read_only, nil, "a.md")
    assert {:error, :forbidden} = Agent.restore_file(read_only, nil, "a.md")
    assert {:error, :forbidden} = Agent.restore_version(read_only, nil, "a.md", 1)

    assert {:error, :vault_not_found} = Agent.read_file(stranger, ctx.vault.id, "a.md")
    assert {:error, :vault_not_found} = Agent.list_directory(stranger, "No such vault")
    assert Agent.list_vaults(stranger) == []
    assert read(ctx.scope, "a.md") == "secret"
  end

  describe "text files that are not notes" do
    test "are created, read, searched, edited and replaced like notes", %{
      scope: scope,
      vault: vault
    } do
      csv = "name,city\nAda,London\n"

      assert {:ok, %{outcome: :created, lines: 2}} =
               Agent.write_file(scope, nil, "Data/people.csv", csv)

      assert %{kind: :blob} = Vaults.get_entry_by_path(vault.id, "Data/people.csv")

      assert {:ok, %{kind: :note, text: ^csv, rev: rev}} =
               Agent.read_file(scope, nil, "Data/people.csv")

      assert {:ok, [%{path: "Data/people.csv", matches: [%{line: 2}]}]} =
               Agent.search_files(scope, nil, "london")

      edit = [%{old_text: "London", new_text: "Paris"}]

      assert {:ok, %{outcome: :updated}} =
               Agent.edit_file(scope, nil, "Data/people.csv", edit, if_rev: rev)

      assert {:error, {:stale, _rev}} =
               Agent.edit_file(scope, nil, "Data/people.csv", edit, if_rev: rev)

      assert {:ok, %{outcome: :updated}} =
               Agent.append_file(scope, nil, "Data/people.csv", "Bo,Oslo\n")

      assert read(scope, "Data/people.csv") == "name,city\nAda,Paris\nBo,Oslo\n"

      assert {:error, :unguarded} = Agent.write_file(scope, nil, "Data/people.csv", "x")

      assert {:ok, %{outcome: :updated}} =
               Agent.write_file(scope, nil, "Data/people.csv", "x\n", overwrite: true)

      assert read(scope, "Data/people.csv") == "x\n"

      entry = Vaults.get_entry_by_path(vault.id, "Data/people.csv")
      assert length(Vaults.list_blob_versions(entry.id)) >= 3
    end

    test "an attachment a device uploaded is text when its bytes are", %{
      scope: scope,
      vault: vault
    } do
      {:ok, text} = Blobs.put(vault.id, ~s({"a": 1}\r\n))
      {:ok, binary} = Blobs.put(vault.id, <<0, 255, 1, 2>>)
      entry(vault, "config.json", %{blob_hash: text.hash, size: text.size})
      entry(vault, "blob.bin", %{blob_hash: binary.hash, size: binary.size})

      assert read(scope, "config.json") == ~s({"a": 1}\n)
      assert {:ok, %{kind: :attachment, image: nil}} = Agent.read_file(scope, nil, "blob.bin")
      assert {:error, :not_a_note} = Agent.append_file(scope, nil, "blob.bin", "x")

      assert {:error, :not_a_note} =
               Agent.write_file(scope, nil, "blob.bin", "x", overwrite: true)
    end

    test "binary files are written whole from base64", %{scope: scope, vault: vault} do
      encoded = Base.encode64(@pixel)

      assert {:ok, %{outcome: :created, kind: :attachment, type: "image/png", bytes: 70}} =
               Agent.write_binary(scope, nil, "Art/pixel.png", encoded)

      assert {:ok, %{image: @pixel}} = Agent.read_file(scope, nil, "Art/pixel.png")
      assert {:error, :unguarded} = Agent.write_binary(scope, nil, "Art/pixel.png", encoded)

      assert {:ok, %{outcome: :updated, bytes: 3}} =
               Agent.write_binary(scope, nil, "Art/pixel.png", Base.encode64("abc"),
                 overwrite: true
               )

      entry = Vaults.get_entry_by_path(vault.id, "Art/pixel.png")
      assert [_now, _before] = Vaults.list_blob_versions(entry.id)

      write(scope, "note.md", "text")
      assert {:error, :not_an_attachment} = Agent.write_binary(scope, nil, "note.md", encoded)
      assert {:error, :not_an_attachment} = Agent.write_binary(scope, nil, "new.md", encoded)
      assert {:error, :invalid_encoding} = Agent.write_binary(scope, nil, "x.png", "not base64!")
      assert {:error, :off_limits} = Agent.write_binary(scope, nil, ".obsidian/x.png", encoded)

      huge = Base.encode64(:binary.copy(<<0>>, 8 * 1024 * 1024 + 1))
      assert {:error, :too_large} = Agent.write_binary(scope, nil, "huge.bin", huge)
    end

    test "Obsidian bases and canvases are notes that merge", %{scope: scope, vault: vault} do
      assert {:ok, %{outcome: :created}} =
               Agent.write_file(scope, nil, "Places/Restaurants.base", "views:\n")

      assert %{kind: :doc} = Vaults.get_entry_by_path(vault.id, "Places/Restaurants.base")

      assert {:ok, %{outcome: :updated}} =
               Agent.append_file(scope, nil, "Places/Restaurants.base", "  - type: table\n")

      assert read(scope, "Places/Restaurants.base") == "views:\n  - type: table\n"
    end
  end

  test "attachments cannot be edited as notes", %{scope: scope, vault: vault} do
    entry(vault, "photo.png")
    edit = [%{old_text: "x", new_text: "y"}]

    assert {:error, :not_a_note} = Agent.append_file(scope, nil, "photo.png", "x")
    assert {:error, :not_a_note} = Agent.edit_file(scope, nil, "photo.png", edit)
    assert {:error, :not_a_note} = Agent.history(scope, nil, "photo.png")
    assert {:error, :invalid_path} = Agent.append_file(scope, nil, "../b.md", "x")
  end
end
