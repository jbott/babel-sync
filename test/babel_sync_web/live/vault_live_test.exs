defmodule BabelSyncWeb.VaultLiveTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures
  import Phoenix.LiveViewTest

  alias BabelSync.{Blobs, Sync, Vaults}
  alias BabelSyncWeb.Paths

  setup %{conn: conn} do
    owner = user()
    vault = vault(owner, %{name: "Research"})
    %{conn: sign_in(conn, owner), anonymous: conn, owner: owner, vault: vault}
  end

  describe "sign-in" do
    test "is required when it is enabled", %{anonymous: conn} do
      Application.put_env(:babel_sync, :auth, [:passkey])
      on_exit(fn -> Application.put_env(:babel_sync, :auth, []) end)

      {:ok, stranger, _html} = live(conn, ~p"/")
      assert has_element?(stranger, "#sign-in")
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/account")
    end

    test "is skipped for the owner in single-user mode without sign-in", %{anonymous: conn} do
      assert {:ok, _view, html} = live(conn, ~p"/account")
      assert html =~ "Vaults"
    end
  end

  describe "home" do
    test "opens the first vault by name", %{conn: conn, owner: owner, vault: research} do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/")
      assert to == Paths.vault(research.id)

      archive = vault(owner, %{name: "Archive"})
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/")
      assert to == Paths.vault(archive.id)
      assert redirected_to(get(conn, ~p"/")) == Paths.vault(archive.id)
    end

    test "opens the account page for someone without a vault", %{anonymous: conn} do
      conn = sign_in(conn, user())

      assert {:error, {:live_redirect, %{to: "/account"}}} = live(conn, ~p"/")
      {:ok, account, _html} = live(conn, ~p"/account")
      assert has_element?(account, "#vaults-empty")
      refute has_element?(account, "#vaults a")
      assert has_element?(account, "#new-vault")
    end

    test "carries a notice through to where it lands", %{conn: conn, vault: vault} do
      {:ok, settings, _html} = live(conn, Paths.settings(vault.id))

      {:ok, account, _html} =
        settings
        |> element("#delete-vault")
        |> render_click()
        |> follow_redirect(conn, ~p"/")
        |> follow_redirect(conn, ~p"/account")

      assert has_element?(account, "#flash-info", "Vault deleted.")
    end
  end

  describe "events no page of ours would send" do
    test "are answered without the page going down", %{conn: conn, vault: vault} do
      note = entry(vault, "Trips/Lisbon plan.md")
      {:ok, view, _html} = live(conn, Paths.entry(note))
      page = Process.monitor(view.pid)
      view |> element("#history-button") |> render_click()

      for {event, params} <- [
            {"show_version", %{"id" => "not a number"}},
            {"show_version", %{"id" => "12abc"}},
            {"show_version", %{"id" => %{"nested" => 1}}},
            {"restore", %{"id" => "999999"}},
            {"restore", %{"id" => "; drop"}},
            {"restore_blob", %{"id" => "x"}},
            {"compare", %{"against" => "nothing"}},
            {"reveal", %{"line" => "9"}},
            {"find", %{"q" => 7}},
            {"toggle_folder", %{"path" => 3, "open" => "yes"}},
            {"open_folders", %{"paths" => [1, %{}]}},
            {"all_folders", %{"open" => "maybe"}},
            {"attach", %{"name" => 5, "hash" => []}},
            {"attach", %{"name" => "a.png", "hash" => "not a hash"}},
            {"create_note", %{"note" => %{"path" => 4}}},
            {"create_note", %{"note" => "flat"}},
            {"rename", %{"rename" => %{"path" => nil}}},
            {"rename", %{"rename" => %{"path" => "../../etc/passwd"}}},
            {"switch_vault", %{"vault" => "not-a-uuid"}},
            {"mode", %{"mode" => "write"}},
            {"base_view", %{"view" => %{}}},
            {"upload_failed", %{"name" => %{}}},
            {"follow", %{"target" => ["a"]}},
            {"never_heard_of_it", %{}}
          ] do
        render_hook(view, event, params)
      end

      refute_received {:DOWN, ^page, :process, _pid, _reason}
      assert has_element?(view, "#entry-path", "Trips/Lisbon plan.md")
    end
  end

  describe "outline and links" do
    test "a note's headings and the notes that link to it are shown beside it", %{
      conn: conn,
      vault: vault
    } do
      plan = entry(vault, "Trips/Lisbon plan.md")
      packing = entry(vault, "Trips/packing.md")
      soup = entry(vault, "Recipes/soup.md")
      :ok = BabelSync.Sync.replace_text(plan.id, "# Lisbon\n\nText.\n\n## Day one\n")
      :ok = BabelSync.Sync.replace_text(packing.id, "For the [[Lisbon plan|trip]].\n")
      :ok = BabelSync.Sync.replace_text(soup.id, "No links, but see [[packing]].\n")
      for note <- [plan, packing, soup], do: :ok = BabelSync.Sync.flush(note.id)

      {:ok, view, _html} = live(conn, Paths.entry(plan))
      refute has_element?(view, "#details")

      view |> element("#details-button") |> render_click()
      assert has_element?(view, "#outline a[href='#md-h-lisbon']", "Lisbon")
      assert has_element?(view, "#outline a", "Day one")

      render_async(view)
      assert has_element?(view, "#linked-from-#{packing.id}", "packing")
      refute has_element?(view, "#linked-from-#{soup.id}")

      view |> element("#linked-from-#{packing.id}") |> render_click()
      assert_patch view, Paths.entry(packing)
      assert has_element?(view, "#outline-empty")
      render_async(view)
      assert has_element?(view, "#linked-from-#{soup.id}")

      view |> element("#history-button") |> render_click()
      refute has_element?(view, "#details")

      view |> element("#details-button") |> render_click()
      assert has_element?(view, "#details")
      refute has_element?(view, "#history")
      render_async(view)
      view |> element("#close-details") |> render_click()
      refute has_element?(view, "#details")
    end
  end

  describe "a link followed from the editor" do
    test "opens the note it names, or says nothing has that name", %{conn: conn, vault: vault} do
      plan = entry(vault, "Trips/Lisbon plan.md")
      packing = entry(vault, "Trips/packing.md")
      {:ok, view, _html} = live(conn, Paths.entry(plan))

      render_hook(view, "follow", %{"target" => "packing#Shoes"})
      assert_patch view, Paths.entry(packing)

      render_hook(view, "follow", %{"target" => "Trips/Lisbon%20plan.md"})
      assert has_element?(view, "#flash-error", "Trips/Lisbon%20plan.md")

      render_hook(view, "follow", %{"target" => "Trips/Lisbon plan.md"})
      assert_patch view, Paths.entry(plan)
    end
  end

  describe "finding" do
    test "files are found by name, best match first, and notes by their text", %{
      conn: conn,
      vault: vault
    } do
      plan = entry(vault, "Trips/Lisbon plan.md")
      entry(vault, "Trips/packing.md")
      soup = entry(vault, "Recipes/soup.md")
      :ok = BabelSync.Sync.replace_text(soup.id, "# Soup\n\nSimmer the lisbon lemons slowly.\n")
      :ok = BabelSync.Sync.flush(soup.id)

      {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}")
      refute has_element?(view, "#finder-dialog")

      view |> element("#find-button") |> render_click()
      assert has_element?(view, "#finder-dialog[role=dialog] #finder-input")
      assert has_element?(view, "#finder-results a", "soup.md")

      view |> form("#finder-form", %{q: "lisb"}) |> render_change()
      assert has_element?(view, "#finder-file-#{plan.id}", "Lisbon plan.md")
      refute has_element?(view, "#finder-results a", "packing.md")
      assert has_element?(view, "#finder-searching")

      render_async(view)
      assert has_element?(view, "#finder-hit-#{soup.id}", "Simmer the lisbon lemons slowly.")
      assert has_element?(view, "#finder-hit-#{soup.id}", "line 3")

      view |> form("#finder-form", %{q: "zzzz"}) |> render_change()
      render_async(view)
      assert has_element?(view, "#finder-nothing")

      view |> form("#finder-form", %{q: "plan"}) |> render_change()
      view |> element("#finder-file-#{plan.id}") |> render_click()
      assert_patch view, Paths.entry(plan)
      refute has_element?(view, "#finder-dialog")
    end

    test "the panel closes when asked, and a late search does not reopen it", %{
      conn: conn,
      vault: vault
    } do
      entry(vault, "note.md")
      {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}")

      render_hook(element(view, "#finder"), "open_finder", %{})
      view |> form("#finder-form", %{q: "note"}) |> render_change()
      render_hook(element(view, "#finder"), "close_finder", %{})
      render_async(view)

      refute has_element?(view, "#finder-dialog")
    end
  end

  describe "folders" do
    test "start closed, except the ones holding the open note", %{conn: conn, vault: vault} do
      entry(vault, "Trips/Lisbon/plan.md")
      entry(vault, "Recipes/soup.md")

      {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}")
      assert has_element?(view, "#tree[phx-hook=Folders]")
      assert has_element?(view, "#open-all-folders")
      assert has_element?(view, "#close-all-folders")
      refute has_element?(view, "#tree details[open]")

      {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/f/Trips/Lisbon/plan.md")
      assert has_element?(view, ~s(#tree details[open][data-path="Trips"]))
      assert has_element?(view, ~s(#tree details[open][data-path="Trips/Lisbon"]))
      refute has_element?(view, ~s(#tree details[open][data-path="Recipes"]))
    end

    test "only send what is inside them once they are opened", %{conn: conn, vault: vault} do
      entry(vault, "Trips/Lisbon/plan.md")
      entry(vault, "Recipes/soup.md")

      {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}")
      refute has_element?(view, "#tree a", "soup.md")
      refute has_element?(view, ~s(#tree details[data-path="Trips/Lisbon"]))

      render_hook(element(view, "#tree"), "toggle_folder", %{"path" => "Recipes", "open" => true})
      assert has_element?(view, "#tree a", "soup.md")
      refute has_element?(view, "#tree a", "plan.md")

      render_hook(element(view, "#tree"), "toggle_folder", %{"path" => "Recipes", "open" => false})

      refute has_element?(view, "#tree a", "soup.md")

      render_hook(element(view, "#tree"), "open_folders", %{"paths" => ["Trips", "Trips/Lisbon"]})
      assert has_element?(view, "#tree a", "plan.md")

      render_hook(element(view, "#tree"), "all_folders", %{"open" => true})
      assert_reply view, %{open: ["Recipes", "Trips", "Trips/Lisbon"]}
      assert has_element?(view, "#tree a", "soup.md")
      assert has_element?(view, "#tree a", "plan.md")

      render_hook(element(view, "#tree"), "all_folders", %{"open" => false})
      assert_reply view, %{open: []}
      refute has_element?(view, "#tree a", "soup.md")
    end

    test "a burst of changes redraws the tree once more, not once each", %{
      conn: conn,
      vault: vault
    } do
      {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}")

      entry(vault, "first.md")
      assert has_element?(view, "#tree a", "first.md")

      for n <- 1..20, do: entry(vault, "burst-#{n}.md")
      refute has_element?(view, "#tree a", "burst-20.md")

      send(view.pid, :list_entries)
      assert has_element?(view, "#tree a", "burst-20.md")
      assert has_element?(view, "#tree a", "burst-1.md")
    end
  end

  describe "vault list" do
    test "shows only the user's vaults and creates new ones", %{conn: conn} do
      vault(user(), %{name: "Someone else's"})
      {:ok, view, _html} = live(conn, ~p"/account")

      assert has_element?(view, "#vaults a", "Research")
      refute has_element?(view, "#vaults", "Someone else")

      view |> form("#new-vault", vault: %{name: "Journal"}) |> render_submit()
      {path, _flash} = assert_redirect(view)
      assert path =~ "/v/"
    end

    test "names the person's role when vaults are shared", %{conn: conn, owner: owner} do
      Application.put_env(:babel_sync, :mode, :multi)
      on_exit(fn -> Application.put_env(:babel_sync, :mode, :single) end)

      shared = vault(user(), %{name: "Shared"})
      {:ok, _member} = Vaults.put_member(shared, owner, :viewer)
      {:ok, view, _html} = live(conn, ~p"/account")

      assert has_element?(view, "#vaults a", "owner")
      assert has_element?(view, "#vaults a[href='#{Paths.vault(shared.id)}']", "viewer")
    end
  end

  describe "the way back from settings" do
    test "returns to the vault the person came from", %{conn: conn, owner: owner, vault: vault} do
      journal = vault(owner, %{name: "Journal"})
      {:ok, view, _html} = live(conn, Paths.vault(journal.id))

      assert has_element?(view, "#account-link[href='/account?from=#{journal.id}']")

      {:ok, account, _html} = live(conn, ~p"/account?from=#{journal.id}")

      assert has_element?(
               account,
               "#account-back[href='#{Paths.vault(journal.id)}']",
               "Back to Journal"
             )

      refute has_element?(account, "#account-back[href='#{Paths.vault(vault.id)}']")
    end

    test "falls back to the notes for a vault that is unknown or someone else's", %{conn: conn} do
      foreign = vault(user(), %{name: "Someone else's"})

      for from <- [foreign.id, "nonsense", ""] do
        {:ok, account, _html} = live(conn, ~p"/account?from=#{from}")

        assert has_element?(account, "#account-back[href='/']", "Back to notes")
        refute has_element?(account, "#account-back", "Someone else")
      end

      {:ok, account, _html} = live(conn, ~p"/account")
      assert has_element?(account, "#account-back[href='/']", "Back to notes")
    end

    test "is left out for someone without a vault", %{anonymous: conn} do
      conn = sign_in(conn, user())
      {:ok, account, _html} = live(conn, ~p"/account?from=#{Ecto.UUID.generate()}")

      refute has_element?(account, "#account-back")
      assert has_element?(account, "#vaults-empty")
    end
  end

  describe "vault switcher" do
    test "lists the person's vaults and moves between them", %{
      conn: conn,
      owner: owner,
      vault: research
    } do
      journal = vault(owner, %{name: "Journal"})
      hidden = vault(user(), %{name: "Someone else's"})
      {:ok, view, _html} = live(conn, Paths.vault(research.id))

      assert has_element?(view, "#vault-switcher option[selected]", "Research")
      assert has_element?(view, "#vault-switcher option", "Journal")
      refute has_element?(view, "#vault-switcher option", "Someone else")

      view |> element("#vault-switcher-form") |> render_change(%{"vault" => hidden.id})
      refute_redirected(view, Paths.vault(hidden.id))

      view |> element("#vault-switcher-form") |> render_change(%{"vault" => journal.id})
      assert_redirect(view, Paths.vault(journal.id))
    end

    test "leads to where vaults are managed", %{conn: conn, vault: vault} do
      {:ok, view, _html} = live(conn, Paths.vault(vault.id))

      view |> element("#vault-switcher-form") |> render_change(%{"vault" => "manage"})
      assert_redirect(view, "/account")
    end
  end

  describe "vault" do
    test "lists the tree and opens a note in the editor", %{conn: conn, vault: vault} do
      note = entry(vault, "Projects/plan.md")
      entry(vault, "Projects/diagram.png")

      {:ok, view, _html} = live(conn, Paths.entry(note))

      assert has_element?(view, "#tree", "Projects")
      assert has_element?(view, "#tree a", "plan.md")
      assert has_element?(view, "#tree a", "diagram.png")
      assert has_element?(view, "#entry-path", "Projects/plan.md")
      assert has_element?(view, "#editor-#{note.id}[phx-hook='Editor'][data-writable='true']")
    end

    test "read mode renders markdown safely and follows live edits", %{conn: conn, vault: vault} do
      note = entry(vault, "note.md")
      entry(vault, "Other.md")
      :ok = Sync.replace_text(note.id, "# Heading\n\n[[Other]]\n\n<script>alert(1)</script>")
      {:ok, view, _html} = live(conn, Paths.entry(note))

      html = view |> element("button", "Read") |> render_click()
      assert has_element?(view, "#preview-body h1", "Heading")
      assert html =~ ~s(href="/v/#{vault.id}/f/Other.md")
      refute html =~ "<script>alert"

      :ok = Sync.replace_text(note.id, "# Changed elsewhere")
      send(view.pid, :render_preview)
      assert has_element?(view, "#preview-body h1", "Changed elsewhere")

      other = Vaults.get_entry_by_path(vault.id, "Other.md")
      :ok = Sync.replace_text(other.id, "Shown in place")
      :ok = Sync.replace_text(note.id, "![[Other]]")
      send(view.pid, :render_preview)
      assert has_element?(view, "#preview-body .embed-content p", "Shown in place")
    end

    test "canvases open drawn while notes keep the mode last chosen for notes", %{
      conn: conn,
      vault: vault
    } do
      board = entry(vault, "Board.canvas")
      note = entry(vault, "note.md")
      {:ok, view, _html} = live(conn, Paths.entry(note))
      assert has_element?(view, "#editor-#{note.id}")

      render_patch(view, Paths.entry(board))
      assert has_element?(view, "#canvas")
      view |> element("button", "Edit") |> render_click()
      assert has_element?(view, "#editor-#{board.id}")

      render_patch(view, Paths.entry(note))
      assert has_element?(view, "#editor-#{note.id}")
      view |> element("button", "Read") |> render_click()

      render_patch(view, Paths.entry(board))
      assert has_element?(view, "#canvas")
      render_patch(view, Paths.entry(note))
      assert has_element?(view, "#preview-body")
    end

    test "a canvas is drawn as a board of cards, and a broken one is shown as text", %{
      conn: conn,
      vault: vault
    } do
      board = entry(vault, "Board.canvas")

      canvas = %{
        "nodes" => [
          %{
            "id" => "a",
            "type" => "text",
            "text" => "# Idea",
            "x" => 0,
            "y" => 0,
            "width" => 200,
            "height" => 80
          },
          %{
            "id" => "b",
            "type" => "text",
            "text" => "next",
            "x" => 300,
            "y" => 0,
            "width" => 200,
            "height" => 80
          }
        ],
        "edges" => [%{"id" => "e", "fromNode" => "a", "toNode" => "b"}]
      }

      :ok = Sync.replace_text(board.id, Jason.encode!(canvas))
      {:ok, view, _html} = live(conn, Paths.entry(board))

      assert has_element?(view, "#canvas[phx-hook=Canvas] .canvas-node h1", "Idea")
      assert has_element?(view, "#canvas .canvas-edge")
      assert has_element?(view, "#canvas-fit")

      :ok = Sync.replace_text(board.id, "{not json")
      send(view.pid, :render_preview)
      refute has_element?(view, "#canvas")
      assert has_element?(view, "#preview-body .callout", "not valid JSON")
    end

    test "a map view sends its places, with links to their notes, to the map", %{
      conn: conn,
      vault: vault
    } do
      cafe = entry(vault, "Places/Cafe.md")

      :ok =
        Sync.replace_text(
          cafe.id,
          "---\ncoordinates: 37.75, -122.47\nsite: \"[Menu](https://example.com/menu)\"\n---\n"
        )

      base = entry(vault, "Places.base")

      :ok =
        Sync.replace_text(base.id, """
        properties:
          note.site:
            displayName: Website
        views:
          - type: map
            name: Map
            order: [file.name, site]
            coordinates: note.coordinates
            defaultZoom: 3
          - type: table
            name: List
        """)

      {:ok, view, _html} = live(conn, Paths.entry(base))
      render_async(view)

      [places] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#base-map")
        |> LazyHTML.attribute("data-places")

      assert %{"columns" => ["file.name", "Website"], "zoom" => 3, "markers" => [marker]} =
               Jason.decode!(places)

      assert %{"latitude" => 37.75, "href" => href, "title" => "Cafe"} = marker
      assert href == Paths.entry(cafe)

      assert marker["fields"] == [
               [%{"kind" => "text", "text" => "Cafe"}],
               [%{"kind" => "web", "href" => "https://example.com/menu", "text" => "Menu"}]
             ]

      refute has_element?(view, "#base-table")
    end

    test "a base is shown as a table of its notes, one tab per view", %{
      conn: conn,
      vault: vault
    } do
      notes =
        for {name, status, extra} <- [
              {"Alpha", "open",
               "source: \"[[Beta]]\"\nsite: \"[Docs](https://example.com/docs)\""},
              {"Beta", "done", "site: https://example.org\nmade: 2024-03-09T08:00:00Z"}
            ],
            into: %{} do
          note = entry(vault, "Tasks/#{name}.md")
          :ok = Sync.replace_text(note.id, "---\nstatus: #{status}\n#{extra}\n---\n# #{name}")
          {name, note}
        end

      base = entry(vault, "Tasks.base")

      :ok =
        Sync.replace_text(base.id, """
        filters: file.inFolder("Tasks")
        properties:
          note.status:
            displayName: State
        views:
          - type: table
            name: All
            groupBy:
              property: status
              direction: DESC
            order: [file.name, status, source, site, made]
          - type: table
            name: Open
            filters: status == "open"
            order: [status]
        """)

      assert conn |> get(Paths.entry(base)) |> html_response(200) =~ ~s(id="base-loading")

      {:ok, view, _html} = live(conn, Paths.entry(base))
      render_async(view)

      assert has_element?(view, "#base-table th", "State")
      refute has_element?(view, "#base-table th", "file.name")
      assert has_element?(view, ~s(#base-table a[href="#{Paths.entry(notes["Beta"])}"]), "Beta")
      assert has_element?(view, "#base-table td", "done")

      headings =
        view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#base-table tbody th")

      assert Enum.map(headings, &String.trim(LazyHTML.text(&1))) == ["open", "done"]

      assert has_element?(
               view,
               ~s(#base-table td a[href="#{Paths.entry(notes["Beta"])}"]),
               "Beta"
             )

      assert has_element?(
               view,
               ~s(#base-table td a[href="https://example.com/docs"][target=_blank]),
               "Docs"
             )

      assert has_element?(view, ~s(#base-table td a[href="https://example.org"]))
      assert has_element?(view, "#base-table td", "9 Mar 2024")

      :ok = Sync.replace_text(notes["Beta"].id, "---\nstatus: shipped\n---\n# Beta")
      :ok = Sync.flush(notes["Beta"].id)
      _ = :sys.get_state(view.pid)
      send(view.pid, :render_preview)
      render_async(view)
      assert has_element?(view, "#base-table td", "shipped")

      view |> element("#base-views button", "Open") |> render_click()
      render_async(view)
      assert has_element?(view, "#base-views [aria-pressed=true]", "Open")
      assert has_element?(view, "#base-table a", "Alpha")
      refute has_element?(view, "#base-table a", "Beta")

      :ok = Sync.replace_text(base.id, "filters: \"(((\"")
      send(view.pid, :render_preview)
      render_async(view)
      assert has_element?(view, "#preview-body .callout", "could not be run")
    end

    test "creates, renames and deletes notes", %{conn: conn, vault: vault} do
      {:ok, view, _html} = live(conn, Paths.vault(vault.id))

      view |> form("#new-note", note: %{path: "Inbox/idea"}) |> render_submit()
      assert_patch(view, "/v/#{vault.id}/f/Inbox/idea.md")
      created = Vaults.get_entry_by_path(vault.id, "Inbox/idea.md")
      assert created.kind == :doc

      view |> element("#rename-button") |> render_click()
      view |> form("#rename-form", rename: %{path: "Archive/idea.md"}) |> render_submit()
      assert_patch(view, "/v/#{vault.id}/f/Archive/idea.md")
      assert Vaults.get_entry(created.id).path == "Archive/idea.md"

      view |> element("#delete-button") |> render_click()
      assert_patch(view, "/v/#{vault.id}")
      assert Vaults.list_entries(vault.id) == []
    end

    test "changes made by other clients appear without reloading", %{conn: conn, vault: vault} do
      {:ok, view, _html} = live(conn, Paths.vault(vault.id))

      note = entry(vault, "from-obsidian.md")
      assert has_element?(view, "#tree a", "from-obsidian.md")

      {:ok, _} = Vaults.delete_entry(note)
      send(view.pid, :list_entries)
      refute has_element?(view, "#tree a", "from-obsidian.md")
    end

    test "an uploaded file is attached next to the open note", %{conn: conn, vault: vault} do
      note = entry(vault, "Trips/japan.md")
      {:ok, blob} = Blobs.put(vault.id, "jpeg bytes")
      {:ok, view, _html} = live(conn, Paths.entry(note))

      render_hook(view, "attach", %{"name" => "../../photo.jpg", "hash" => blob.hash})

      assert_patch(view, "/v/#{vault.id}/f/Trips/photo.jpg")
      assert has_element?(view, "#attachment img")
      assert Vaults.get_entry_by_path(vault.id, "Trips/photo.jpg").blob_hash == blob.hash
    end

    test "history lists versions and restores one", %{conn: conn, vault: vault} do
      note = entry(vault, "note.md")
      :ok = Sync.replace_text(note.id, "first draft")
      :ok = Sync.flush(note.id)
      :ok = Sync.replace_text(note.id, "second draft")
      {:ok, view, _html} = live(conn, Paths.entry(note))

      view |> element("#history-button") |> render_click()
      [_second, first] = Sync.list_versions(note.id)
      html = view |> element("#version-#{first.id}") |> render_click()
      assert html =~ "first draft"
      assert has_element?(view, "#version-changes")

      view |> element("#compare-now") |> render_click()
      assert has_element?(view, "#version-changes span", "second")

      view |> element("#compare-text") |> render_click()
      assert has_element?(view, "#version-content", "first draft")

      view |> element("#restore-button") |> render_click()
      assert Sync.text(note.id) == "first draft"
    end

    test "a viewer can read but is offered no way to change anything", ctx do
      viewer = user()
      {:ok, _} = Vaults.put_member(ctx.vault, viewer, :viewer)
      note = entry(ctx.vault, "note.md")
      :ok = Sync.replace_text(note.id, "# Read me")

      {:ok, view, html} = ctx.anonymous |> sign_in(viewer) |> live(Paths.entry(note))

      assert html =~ "Read me</h1>"
      assert has_element?(view, "#preview-body h1", "Read me")
      refute has_element?(view, "#new-note")
      refute has_element?(view, "#delete-button")
      refute has_element?(view, "#vault-settings")

      render_hook(view, "delete", %{})
      assert Vaults.get_entry(note.id).deleted_at == nil
    end

    test "someone outside the vault is turned away", %{anonymous: conn, vault: vault} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> sign_in(user()) |> live(Paths.vault(vault.id))
    end
  end

  describe "reconnecting" do
    test "a reconnect keeps the open note even though the vault switcher is a form", %{
      conn: conn,
      vault: vault
    } do
      note = entry(vault, "note.md")
      {:ok, view, _html} = live(conn, Paths.entry(note))

      assert has_element?(view, "#vault-switcher-form[phx-auto-recover=ignore]")
      view |> form("#vault-switcher-form", vault: vault.id) |> render_change()
      assert has_element?(view, "#entry-path", "note.md")
    end

    defp put_manifest(latest),
      do: Phoenix.Config.put(BabelSyncWeb.Endpoint, :cache_static_manifest_latest, latest)

    test "a page running assets older than the server's is told to reload", %{
      conn: conn,
      vault: vault
    } do
      previous = BabelSyncWeb.Endpoint.config(:cache_static_manifest_latest)
      on_exit(fn -> put_manifest(previous) end)
      current = "/assets/js/app-c0ffee.js"
      put_manifest(%{"js/app.js" => "js/app-c0ffee.js"})

      {:ok, stale, _html} =
        conn
        |> put_connect_params(%{
          "_track_static" => ["http://www.example.com/assets/js/app-0ld.js"]
        })
        |> live(Paths.vault(vault.id))

      assert_push_event(stale, "assets-changed", %{})

      {:ok, fresh, _html} =
        conn
        |> put_connect_params(%{"_track_static" => ["http://www.example.com" <> current]})
        |> live(Paths.vault(vault.id))

      refute_push_event(fresh, "assets-changed", %{})
    end
  end

  describe "raw files" do
    test "serves attachments sandboxed with their type, and notes as text", %{
      conn: conn,
      vault: vault
    } do
      {:ok, blob} = Blobs.put(vault.id, "<svg onload='alert(1)'/>")
      image = entry(vault, "art/logo.svg", %{blob_hash: blob.hash})
      note = entry(vault, "note.md")
      :ok = Sync.replace_text(note.id, "plain")

      served = get(conn, Paths.raw(image))
      assert response(served, 200) =~ "<svg"
      assert get_resp_header(served, "content-type") |> hd() =~ "image/svg+xml"
      assert get_resp_header(served, "content-security-policy") |> hd() =~ "sandbox"

      assert conn |> get(Paths.raw(note)) |> response(200) == "plain"
    end

    test "a PDF opens in a frame and is still served sandboxed", %{conn: conn, vault: vault} do
      {:ok, blob} = Blobs.put(vault.id, "<html><script>alert(1)</script>")
      pdf = entry(vault, "paper.pdf", %{blob_hash: blob.hash})

      served = get(conn, Paths.raw(pdf))
      assert get_resp_header(served, "content-type") |> hd() =~ "application/pdf"
      assert get_resp_header(served, "content-security-policy") |> hd() =~ "sandbox"

      {:ok, view, _html} = live(conn, Paths.entry(pdf))
      assert has_element?(view, ~s(#attachment-pdf[src="#{Paths.raw(pdf)}"]))
    end

    test "refuses people outside the vault", %{anonymous: conn, vault: vault} do
      note = entry(vault, "note.md")

      assert conn |> sign_in(user()) |> get(Paths.raw(note)) |> response(404)
    end
  end

  describe "change notices" do
    test "one that arrives after a newer one for the same entry is ignored", %{
      conn: conn,
      vault: vault
    } do
      note = entry(vault, "ghost.md")
      {:ok, view, _html} = live(conn, Paths.vault(vault.id))
      assert has_element?(view, "#sidebar", "ghost.md")

      {:ok, [_deleted]} = Vaults.delete_entry(note)
      refute has_element?(view, "#sidebar", "ghost.md")

      send(view.pid, {:entry_changed, note})
      refute has_element?(view, "#sidebar", "ghost.md")
    end
  end

  describe "trash and attachment history" do
    test "a deleted note is restored from the trash or removed for good", %{
      conn: conn,
      vault: vault
    } do
      {:ok, [note]} = vault |> entry("idea.md") |> Vaults.delete_entry()
      {:ok, [junk]} = vault |> entry("junk.md") |> Vaults.delete_entry()

      {:ok, view, _html} = live(conn, Paths.trash(vault.id))
      assert has_element?(view, "#trashed-#{note.id}", "idea.md")

      view |> element("#trashed-#{note.id} button", "Restore") |> render_click()
      refute has_element?(view, "#trashed-#{note.id}")
      assert Vaults.get_entry_by_path(vault.id, "idea.md").id == note.id

      view |> element("#trashed-#{junk.id} button", "Delete forever") |> render_click()
      assert has_element?(view, "#trash-empty")
      refute Vaults.get_entry(junk.id)
    end

    test "a viewer sees the trash but cannot change it", %{vault: vault, anonymous: conn} do
      viewer = user()
      {:ok, _member} = Vaults.put_member(vault, viewer, :viewer)
      {:ok, [note]} = vault |> entry("idea.md") |> Vaults.delete_entry()

      {:ok, view, _html} = conn |> sign_in(viewer) |> live(Paths.trash(vault.id))
      assert has_element?(view, "#trashed-#{note.id}")
      refute has_element?(view, "#trashed-#{note.id} button")
      render_click(view, "purge", %{"id" => note.id})
      assert Vaults.get_entry(note.id)
    end

    test "an earlier version of an attachment is restored", %{conn: conn, vault: vault} do
      {:ok, first} = Blobs.put(vault.id, "first")
      {:ok, second} = Blobs.put(vault.id, "second")

      {:ok, file} =
        Vaults.create_entry(vault.id, %{path: "data.bin", blob_hash: first.hash, size: 5})

      {:ok, file} = Vaults.update_entry(file, %{blob_hash: second.hash, size: 6})
      [_current, original] = Vaults.list_blob_versions(file.id)

      {:ok, view, _html} = live(conn, Paths.entry(file))
      view |> element("#history-button") |> render_click()
      assert has_element?(view, "#blob-history li", "current")

      view |> element("#blob-version-#{original.id} button") |> render_click()
      assert Vaults.get_entry(file.id).blob_hash == first.hash
      refute has_element?(view, "#blob-version-#{original.id} button")
    end
  end

  describe "settings" do
    test "an owner can open the .obsidian folder to agents and close it again", ctx do
      {:ok, view, _html} = live(ctx.conn, Paths.settings(ctx.vault.id))
      refute Vaults.get_vault(ctx.vault.id).agents_see_config

      view |> form("#agent-access", agents_see_config: "true") |> render_change()
      assert Vaults.get_vault(ctx.vault.id).agents_see_config
      assert has_element?(view, "#agents-see-config[checked]")

      view |> form("#agent-access") |> render_change(%{agents_see_config: "false"})
      refute Vaults.get_vault(ctx.vault.id).agents_see_config
    end

    test "only owners can open them", ctx do
      editor = user()
      {:ok, _} = Vaults.put_member(ctx.vault, editor, :editor)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               ctx.anonymous |> sign_in(editor) |> live(Paths.settings(ctx.vault.id))
    end

    test "rename and delete the vault", %{conn: conn, vault: vault} do
      {:ok, view, _html} = live(conn, Paths.settings(vault.id))

      view |> form("#rename-vault", vault: %{name: "Renamed"}) |> render_submit()
      assert Vaults.get_vault(vault.id).name == "Renamed"

      view |> element("#delete-vault") |> render_click()
      assert Vaults.get_vault(vault.id) == nil
    end

    test "sharing is offered only in multi-user mode and keeps one owner", %{
      conn: conn,
      vault: vault,
      owner: owner
    } do
      {:ok, view, _html} = live(conn, Paths.settings(vault.id))
      refute has_element?(view, "#members")

      Application.put_env(:babel_sync, :mode, :multi)
      on_exit(fn -> Application.put_env(:babel_sync, :mode, :single) end)
      friend = user(%{email: "friend@example.com"})
      {:ok, view, _html} = live(conn, Paths.settings(vault.id))

      view
      |> form("#add-member", member: %{email: "friend@example.com", role: "viewer"})
      |> render_submit()

      assert Vaults.role(friend, vault.id) == :viewer

      render_change(view, "set_role", %{"user_id" => friend.id, "role" => "editor"})
      assert Vaults.role(friend, vault.id) == :editor

      assert render_click(view, "remove_member", %{"user_id" => owner.id}) =~ "at least one owner"
      assert Vaults.role(owner, vault.id) == :owner

      render_click(view, "remove_member", %{"user_id" => friend.id})
      assert Vaults.role(friend, vault.id) == nil

      view
      |> form("#add-member", member: %{email: " Newcomer@Example.com", role: "viewer"})
      |> render_submit()

      assert has_element?(view, "[id^=invitation-]", "newcomer@example.com")
      assert has_element?(view, "#flash-info", "when they first sign in")
      assert BabelSync.Auth.MagicLink.permitted?("newcomer@example.com")
      refute BabelSync.Auth.MagicLink.permitted?("stranger@example.com")

      view
      |> form("#add-member", member: %{email: "newcomer@example.com", role: "editor"})
      |> render_submit()

      assert [%{role: :editor} = invitation] = Vaults.list_invitations(vault)

      view
      |> form("#add-member", member: %{email: "withdrawn@example.com", role: "editor"})
      |> render_submit()

      [withdrawn] = Vaults.list_invitations(vault) -- [invitation]
      view |> element("#revoke-invitation-#{withdrawn.id}") |> render_click()
      refute has_element?(view, "#invitation-#{withdrawn.id}")

      newcomer = BabelSync.Accounts.user_for_email("newcomer@example.com")
      assert Vaults.role(newcomer, vault.id) == :editor
      assert Vaults.list_invitations(vault) == []

      assert Vaults.role(BabelSync.Accounts.user_for_email("withdrawn@example.com"), vault.id) ==
               nil

      assert view
             |> form("#add-member", member: %{email: "not an address", role: "viewer"})
             |> render_submit() =~ "not an email address"
    end
  end

  describe "edge cases in the vault view" do
    test "a path that does not exist says so", %{conn: conn, vault: vault} do
      {:ok, view, _html} = live(conn, "/v/#{vault.id}/f/missing.md")
      assert render(view) =~ "missing.md does not exist"
      refute has_element?(view, "#entry-path")
    end

    test "creating an existing or invalid note does not clobber anything", %{
      conn: conn,
      vault: vault
    } do
      existing = entry(vault, "idea.md")
      :ok = Sync.replace_text(existing.id, "precious")
      {:ok, view, _html} = live(conn, Paths.vault(vault.id))

      view |> form("#new-note", note: %{path: "idea"}) |> render_submit()
      assert_patch(view, "/v/#{vault.id}/f/idea.md")
      assert Sync.text(existing.id) == "precious"

      html = view |> form("#new-note", note: %{path: "../outside"}) |> render_submit()
      assert html =~ "not a valid path"
      assert [_only] = Vaults.list_entries(vault.id)
    end

    test "renaming onto another file or an invalid path is refused, and can be cancelled", %{
      conn: conn,
      vault: vault
    } do
      note = entry(vault, "a.md")
      entry(vault, "b.md")
      {:ok, view, _html} = live(conn, Paths.entry(note))

      view |> element("#rename-button") |> render_click()

      assert view |> form("#rename-form", rename: %{path: "b.md"}) |> render_submit() =~
               "already exists"

      assert view |> form("#rename-form", rename: %{path: "../x.md"}) |> render_submit() =~
               "not a valid path"

      assert Vaults.get_entry(note.id).path == "a.md"

      render_click(view, "cancel_rename", %{})
      refute has_element?(view, "#rename-form")
    end

    test "the open note follows a rename and a delete made elsewhere", %{conn: conn, vault: vault} do
      note = entry(vault, "a.md")
      {:ok, view, _html} = live(conn, Paths.entry(note))

      {:ok, _moved} = Vaults.rename_entry(note, "Moved/a.md")
      assert_patch(view, "/v/#{vault.id}/f/Moved/a.md")
      assert has_element?(view, "#entry-path", "Moved/a.md")

      {:ok, _deleted} = Vaults.delete_entry(Vaults.get_entry(note.id))
      assert_patch(view, "/v/#{vault.id}")
      assert render(view) =~ "was deleted"

      render_click(view, "rename", %{"rename" => %{"path" => "ghost.md"}})
      refute Vaults.get_entry_by_path(vault.id, "ghost.md")
    end

    test "attaching replaces a file of the same name and reports failures", %{
      conn: conn,
      vault: vault
    } do
      {:ok, first} = Blobs.put(vault.id, "first")
      {:ok, second} = Blobs.put(vault.id, "second")
      {:ok, view, _html} = live(conn, Paths.vault(vault.id))

      render_hook(view, "attach", %{"name" => "photo.jpg", "hash" => first.hash})
      render_hook(view, "attach", %{"name" => "photo.jpg", "hash" => second.hash})
      photo = Vaults.get_entry_by_path(vault.id, "photo.jpg")
      assert photo.blob_hash == second.hash
      assert length(Vaults.list_blob_versions(photo.id)) == 2

      assert render_hook(view, "attach", %{"name" => "x.jpg", "hash" => String.duplicate("0", 64)}) =~
               "Could not attach"

      assert render_hook(view, "upload_failed", %{"name" => "big.mov"}) =~
               "Uploading big.mov failed"
    end

    test "attachments show by type and sizes are readable", %{conn: conn, vault: vault} do
      {:ok, clip} = Blobs.put(vault.id, :binary.copy("v", 2048))

      {:ok, video} =
        Vaults.create_entry(vault.id, %{
          path: "Clips/clip.mp4",
          blob_hash: clip.hash,
          size: clip.size
        })

      {:ok, sound} =
        Vaults.create_entry(vault.id, %{
          path: "sound.mp3",
          blob_hash: clip.hash,
          size: 3 * 1024 * 1024
        })

      {:ok, other} =
        Vaults.create_entry(vault.id, %{path: "data.zip", blob_hash: clip.hash, size: 10})

      {:ok, folder} = Vaults.create_entry(vault.id, %{path: "Clips", kind: :folder})

      {:ok, view, _html} = live(conn, Paths.entry(video))
      assert has_element?(view, "#attachment video")
      assert render(view) =~ "2.0 KB"

      {:ok, view, _html} = live(conn, Paths.entry(sound))
      assert has_element?(view, "#attachment audio")
      assert render(view) =~ "3.0 MB"

      {:ok, view, _html} = live(conn, Paths.entry(other))
      assert has_element?(view, "#attachment a[download]")

      {:ok, view, _html} = live(conn, Paths.entry(folder))
      {:ok, blob} = Blobs.put(vault.id, "in folder")
      render_hook(view, "attach", %{"name" => "inside.png", "hash" => blob.hash})
      assert Vaults.get_entry_by_path(vault.id, "Clips/inside.png")
    end

    test "history can be closed and a vanished attachment version is reported", %{
      conn: conn,
      vault: vault
    } do
      {:ok, blob} = Blobs.put(vault.id, "one")
      {:ok, file} = Vaults.create_entry(vault.id, %{path: "f.bin", blob_hash: blob.hash, size: 3})
      {:ok, view, _html} = live(conn, Paths.entry(file))

      view |> element("#history-button") |> render_click()
      assert render_click(view, "restore_blob", %{"id" => "999999"}) =~ "no longer available"
      render_click(view, "close_history", %{})
      refute has_element?(view, "#blob-history")
    end

    test "an empty vault name is rejected on both forms", %{conn: conn, vault: vault} do
      {:ok, account, _html} = live(conn, ~p"/account")
      account |> form("#new-vault", vault: %{name: ""}) |> render_submit()
      assert [_only] = Vaults.list_vaults(Vaults.list_members(vault) |> hd() |> Map.fetch!(:user))

      {:ok, settings, _html} = live(conn, Paths.settings(vault.id))
      settings |> form("#rename-vault", vault: %{name: ""}) |> render_submit()
      assert Vaults.get_vault(vault.id).name == "Research"
    end
  end

  describe "raw files, edge cases" do
    test "missing files, folders and malformed vault ids are not found", %{
      conn: conn,
      vault: vault
    } do
      {:ok, _folder} = Vaults.create_entry(vault.id, %{path: "Dir", kind: :folder})

      {:ok, _dangling} =
        Vaults.create_entry(vault.id, %{
          path: "lost.bin",
          blob_hash: String.duplicate("e", 64),
          size: 1
        })

      for path <- [
            "/v/#{vault.id}/raw/nope.png",
            "/v/#{vault.id}/raw/Dir",
            "/v/#{vault.id}/raw/lost.bin",
            "/v/not-a-uuid/raw/x"
          ] do
        assert conn |> get(path) |> response(404), path
      end
    end
  end
end
