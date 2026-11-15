defmodule BabelSyncWeb.SourcesLiveTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures
  import Phoenix.LiveViewTest

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Agent, Sources, Vaults}

  @source """
  /* source
  hosts: [api.example.com]
  secrets:
    token: { host: api.example.com, header: "Authorization: Bearer {}" }
  */
  vault.item("one", { path: "One.md", properties: { seen: true }, body: "# One\\n" })
  """

  setup %{conn: conn} do
    with_auth([:passkey])
    owner = user()
    {:ok, vault} = Vaults.update_vault(vault(owner), %{sources_folder: "Data"})
    {:ok, _} = Agent.write_file(Scope.for_user(owner), vault.id, "Data/Things.js", @source)
    entry = Vaults.get_entry_by_path(vault.id, "Data/Things.js")
    %{conn: sign_in(conn, owner), owner: owner, vault: vault, entry: entry}
  end

  test "shows a new source with what it asks for and its code", %{
    conn: conn,
    vault: vault,
    entry: entry
  } do
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources")

    assert has_element?(view, "#source-#{entry.id}")
    assert has_element?(view, "#approve-#{entry.id}")
    assert has_element?(view, "#code-#{entry.id}", "One.md")
    refute has_element?(view, "#run-#{entry.id}")
  end

  test "approving lets it run, and a run shows what it did", %{
    conn: conn,
    vault: vault,
    entry: entry
  } do
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources")

    view |> element("#approve-#{entry.id}") |> render_click()

    assert [source] = Sources.list(vault.id)
    refute has_element?(view, "#approve-#{entry.id}")
    assert has_element?(view, "#run-#{entry.id}")

    Sources.enqueue(source, "manual")
    [{run, claimed}] = Sources.Scheduler.claim(DateTime.utc_now())
    Sources.Scheduler.carry_out(run, claimed)

    assert has_element?(view, "[id^=outcome-]", "Looked at 1 note: 1 new")
    assert has_element?(view, "[id^=run-time-]")
    assert Vaults.get_entry_by_path(vault.id, "Data/Things/One.md")
  end

  test "a script with a secret, changed after approval, asks to be approved again", %{
    conn: conn,
    vault: vault,
    entry: entry,
    owner: owner
  } do
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources")
    view |> element("#approve-#{entry.id}") |> render_click()

    {:ok, _} =
      Agent.edit_file(Scope.for_user(owner), vault.id, "Data/Things.js", [
        %{old_text: "seen: true", new_text: "seen: false"}
      ])

    assert has_element?(view, "#approve-#{entry.id}")
    assert has_element?(view, "#code-#{entry.id}", "seen: false")
    assert has_element?(view, "#run-#{entry.id}")
  end

  test "a secret is saved and never shown", %{conn: conn, vault: vault, entry: entry} do
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources")
    view |> element("#approve-#{entry.id}") |> render_click()

    html =
      view
      |> form("#secret-#{entry.id}-token", %{value: "hunter2"})
      |> render_submit()

    refute html =~ "hunter2"
    assert [source] = Sources.list(vault.id)
    assert Sources.Secrets.open(source) == %{"token" => "hunter2"}
  end

  test "someone who is not an owner is turned away", %{conn: conn, vault: vault} do
    editor = user()
    Vaults.put_member(vault, editor, :editor)

    assert {:error, {:live_redirect, %{to: "/"}}} =
             conn |> recycle() |> sign_in(editor) |> live(~p"/v/#{vault.id}/sources")
  end

  test "settings link to the sources page", %{conn: conn, vault: vault} do
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/settings")

    assert has_element?(view, "#open-sources")
  end

  test "a script with no secret is edited without asking again", %{
    conn: conn,
    vault: vault,
    owner: owner
  } do
    plain = "/* source\nhosts: [api.example.com]\n*/\nlog(1)\n"
    {:ok, _} = Agent.write_file(Scope.for_user(owner), vault.id, "Data/Plain.js", plain)
    plain_entry = Vaults.get_entry_by_path(vault.id, "Data/Plain.js")
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources")
    view |> element("#approve-#{plain_entry.id}") |> render_click()

    {:ok, _} =
      Agent.edit_file(Scope.for_user(owner), vault.id, "Data/Plain.js", [
        %{old_text: "log(1)", new_text: "log(2)"}
      ])

    _ = render(view)
    refute has_element?(view, "#approve-#{plain_entry.id}")
    assert has_element?(view, "#run-#{plain_entry.id}")
  end

  test "the sources folder is picked in settings", %{conn: conn, vault: vault, entry: entry} do
    {:ok, settings, _html} = live(conn, ~p"/v/#{vault.id}/settings")

    settings
    |> form("#sources-folder", %{vault: %{sources_folder: "Elsewhere"}})
    |> render_submit()

    assert Vaults.get_vault(vault.id).sources_folder == "Elsewhere"

    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources")
    refute has_element?(view, "#source-#{entry.id}")
    assert has_element?(view, "#sources-empty")
  end
end
