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
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources/#{entry.id}")

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
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources/#{entry.id}")

    view |> element("#approve-#{entry.id}") |> render_click()

    assert [source] = Sources.list(vault.id)
    refute has_element?(view, "#approve-#{entry.id}")
    assert has_element?(view, "#run-#{entry.id}")

    Sources.enqueue(source, "manual")
    [{run, claimed}] = Sources.Scheduler.claim(DateTime.utc_now())
    Sources.Scheduler.carry_out(run, claimed)

    assert has_element?(view, "[id^=outcome-]", "1 new, 0 edited")
    assert has_element?(view, "[id^=run-time-]")
    assert Vaults.get_entry_by_path(vault.id, "Data/Things/One.md")
  end

  test "a run leads to the notes it made and edited", %{
    conn: conn,
    vault: vault,
    entry: entry,
    owner: owner
  } do
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources/#{entry.id}")
    view |> element("#approve-#{entry.id}") |> render_click()
    [source] = Sources.list(vault.id)

    run = fn ->
      Sources.enqueue(source, "manual")
      [{run, claimed}] = Sources.Scheduler.claim(DateTime.utc_now())
      Sources.Scheduler.carry_out(run, claimed)
    end

    run.()
    [first] = Sources.runs(source)

    {:ok, _} =
      Agent.edit_file(Scope.for_user(owner), vault.id, "Data/Things/One.md", [
        %{old_text: "seen: true", new_text: "seen: false"}
      ])

    run.()
    run.()
    [idle, second, ^first] = Sources.runs(source)

    assert has_element?(view, "a#outcome-#{second.id}", "0 new, 1 edited")
    refute has_element?(view, "a#outcome-#{idle.id}")

    {:ok, made, _html} =
      view |> element("a#outcome-#{first.id}") |> render_click() |> follow_redirect(conn)

    assert has_element?(made, "#run-notes-time")
    assert has_element?(made, "#count-created", "1")
    assert has_element?(made, "#count-changed", "0")
    assert has_element?(made, "#notes [id^=note-]", "One")

    {:ok, edited, _html} =
      live(
        conn,
        ~p"/v/#{vault.id}/sources/#{entry.id}/notes?#{[run: second.id, show: "created"]}"
      )

    assert has_element?(edited, "#count-changed", "1")
    assert has_element?(edited, "#notes-empty")
    edited |> element("#tab-changed") |> render_click()
    assert has_element?(edited, "#notes [id^=note-]", "One")
  end

  test "a script with a secret, changed after approval, asks to be approved again", %{
    conn: conn,
    vault: vault,
    entry: entry,
    owner: owner
  } do
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources/#{entry.id}")
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
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources/#{entry.id}")
    view |> element("#approve-#{entry.id}") |> render_click()

    html =
      view
      |> form("#secret-#{entry.id}-token", %{value: "hunter2"})
      |> render_submit()

    refute html =~ "hunter2"
    assert [source] = Sources.list(vault.id)
    assert Sources.Secrets.open(source) == %{"token" => "hunter2"}
  end

  test "someone who is not an owner is turned away", %{conn: conn, vault: vault, entry: entry} do
    editor = user()
    Vaults.put_member(vault, editor, :editor)

    assert {:error, {:live_redirect, %{to: "/"}}} =
             conn |> recycle() |> sign_in(editor) |> live(~p"/v/#{vault.id}/sources/#{entry.id}")
  end

  test "settings list the vault's sources, each leading to its own page", %{
    conn: conn,
    vault: vault,
    entry: entry
  } do
    {:ok, settings, _html} = live(conn, ~p"/v/#{vault.id}/settings")

    assert has_element?(settings, "#source-list #source-#{entry.id}", "Things")

    {:ok, view, _html} =
      settings
      |> element("#source-#{entry.id} a")
      |> render_click()
      |> follow_redirect(conn, ~p"/v/#{vault.id}/sources/#{entry.id}")

    assert has_element?(view, "#approve-#{entry.id}")
  end

  test "settings show a source's last run as it happens", %{
    conn: conn,
    vault: vault,
    entry: entry
  } do
    {:ok, source_page, _html} = live(conn, ~p"/v/#{vault.id}/sources/#{entry.id}")
    {:ok, settings, _html} = live(conn, ~p"/v/#{vault.id}/settings")
    refute has_element?(settings, "#last-run-#{entry.id}")

    source_page |> element("#approve-#{entry.id}") |> render_click()
    [source] = Sources.list(vault.id)
    Sources.enqueue(source, "manual")
    [{run, claimed}] = Sources.Scheduler.claim(DateTime.utc_now())
    Sources.Scheduler.carry_out(run, claimed)

    _ = render(settings)
    assert has_element?(settings, "#last-run-#{entry.id}")
    assert has_element?(settings, "#last-outcome-#{entry.id}", "1 new, 0 edited")
  end

  test "a source whose file is gone says so", %{
    conn: conn,
    vault: vault,
    entry: entry,
    owner: owner
  } do
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources/#{entry.id}")
    {:ok, _} = Agent.delete_file(Scope.for_user(owner), vault.id, "Data/Things.js")

    _ = render(view)
    assert has_element?(view, "#source-gone")
    refute has_element?(view, "#source-#{entry.id}")
  end

  test "a script with no secret is edited without asking again", %{
    conn: conn,
    vault: vault,
    owner: owner
  } do
    plain = "/* source\nhosts: [api.example.com]\n*/\nlog(1)\n"
    {:ok, _} = Agent.write_file(Scope.for_user(owner), vault.id, "Data/Plain.js", plain)
    plain_entry = Vaults.get_entry_by_path(vault.id, "Data/Plain.js")
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources/#{plain_entry.id}")
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

    refute has_element?(settings, "#source-#{entry.id}")
    assert has_element?(settings, "#sources-empty")
  end

  test "the notes page lists what a source keeps and restores a deleted note", %{
    conn: conn,
    vault: vault,
    entry: entry,
    owner: owner
  } do
    {:ok, view, _html} = live(conn, ~p"/v/#{vault.id}/sources/#{entry.id}")
    view |> element("#approve-#{entry.id}") |> render_click()
    [source] = Sources.list(vault.id)
    Sources.enqueue(source, "manual")
    [{run, claimed}] = Sources.Scheduler.claim(DateTime.utc_now())
    Sources.Scheduler.carry_out(run, claimed)

    assert has_element?(view, "#source-notes", "1")

    {:ok, notes, _html} =
      view |> element("#source-notes") |> render_click() |> follow_redirect(conn)

    assert has_element?(notes, "#count-current", "1")
    assert has_element?(notes, "#count-deleted", "0")
    assert has_element?(notes, "#notes [id^=note-]", "One")
    refute has_element?(notes, "[id^=reinstate-]")

    {:ok, _} = Agent.delete_file(Scope.for_user(owner), vault.id, "Data/Things/One.md")
    notes |> element("#tab-deleted") |> render_click()

    assert has_element?(notes, "#count-deleted", "1")
    notes |> element("[id^=reinstate-]") |> render_click()

    assert has_element?(notes, "#count-deleted", "0")
    assert has_element?(notes, "#notes-empty")
    refute has_element?(notes, "#notes [id^=note-]")
    assert Vaults.get_entry_by_path(vault.id, "Data/Things/One.md")

    notes |> form("#note-filter", %{q: "nothing like it"}) |> render_change()
    assert has_element?(notes, "#count-all", "0")
  end
end
