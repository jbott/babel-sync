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

      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
    end

    test "is skipped for the owner in single-user mode without sign-in", %{anonymous: conn} do
      assert {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Vaults"
    end
  end

  describe "vault list" do
    test "shows only the user's vaults and creates new ones", %{conn: conn} do
      vault(user(), %{name: "Someone else's"})
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Research"
      refute html =~ "Someone else"

      view |> form("#new-vault", vault: %{name: "Journal"}) |> render_submit()
      {path, _flash} = assert_redirect(view)
      assert path =~ "/v/"
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
      assert html =~ "<h1>Heading</h1>"
      assert html =~ ~s(href="/v/#{vault.id}/f/Other.md")
      refute html =~ "<script>alert"

      :ok = Sync.replace_text(note.id, "# Changed elsewhere")
      send(view.pid, :render_preview)
      assert render(view) =~ "<h1>Changed elsewhere</h1>"
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
      html = view |> element("#history button[phx-value-id='#{first.id}']") |> render_click()
      assert html =~ "first draft"

      view |> element("#restore-button") |> render_click()
      assert Sync.text(note.id) == "first draft"
    end

    test "a viewer can read but is offered no way to change anything", ctx do
      viewer = user()
      {:ok, _} = Vaults.put_member(ctx.vault, viewer, :viewer)
      note = entry(ctx.vault, "note.md")
      :ok = Sync.replace_text(note.id, "# Read me")

      {:ok, view, html} = ctx.anonymous |> sign_in(viewer) |> live(Paths.entry(note))

      assert html =~ "<h1>Read me</h1>"
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

    test "refuses people outside the vault", %{anonymous: conn, vault: vault} do
      note = entry(vault, "note.md")

      assert conn |> sign_in(user()) |> get(Paths.raw(note)) |> response(404)
    end
  end

  describe "settings" do
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

      assert view
             |> form("#add-member", member: %{email: "nobody@example.com", role: "viewer"})
             |> render_submit() =~
               "No account uses"
    end
  end
end
