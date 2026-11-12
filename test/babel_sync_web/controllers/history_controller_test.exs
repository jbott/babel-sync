defmodule BabelSyncWeb.HistoryControllerTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Auth, Sync, Vaults}

  setup %{conn: conn} do
    owner = user()
    vault = vault(owner)
    note = entry(vault, "a.md")
    :ok = Sync.replace_text(note.id, "the quick fox\n")
    :ok = Sync.flush(note.id)
    :ok = Sync.replace_text(note.id, "the slow fox\n")
    :ok = Sync.flush(note.id)
    [newest, oldest] = Sync.list_versions(note.id)
    %{conn: conn, owner: owner, vault: vault, note: note, newest: newest, oldest: oldest}
  end

  defp as(conn, user),
    do:
      put_req_header(conn, "authorization", "Bearer " <> Auth.socket_token(Scope.for_user(user)))

  defp versions(ctx), do: ~p"/api/vaults/#{ctx.vault.id}/notes/#{ctx.note.id}/versions"

  test "versions are listed newest first with what each changed", ctx do
    assert %{"versions" => [newest, oldest]} =
             ctx.conn |> as(ctx.owner) |> get(versions(ctx)) |> json_response(200)

    assert %{"id" => id, "added" => 1, "removed" => 1, "earliest" => false} = newest
    assert id == ctx.newest.id
    assert %{"added" => 1, "removed" => 0, "earliest" => true} = oldest
  end

  test "one version's changes come with the words that changed", ctx do
    assert %{"text" => "the slow fox\n", "changes" => changes} =
             ctx.conn
             |> as(ctx.owner)
             |> get(versions(ctx) <> "/#{ctx.newest.id}")
             |> json_response(200)

    assert %{"hunks" => [%{"lines" => [removed, _added]}]} = changes
    assert removed["segments"] == [["same", "the "], ["removed", "quick"], ["same", " fox"]]
  end

  test "a version compared with now shows what came after it", ctx do
    :ok = Sync.replace_text(ctx.note.id, "the slow brown fox\n")

    assert %{"changes" => %{"added" => 1, "removed" => 1}} =
             ctx.conn
             |> as(ctx.owner)
             |> get(versions(ctx) <> "/#{ctx.newest.id}?against=now")
             |> json_response(200)
  end

  test "restoring puts an old version back for editors only", ctx do
    viewer = user()
    {:ok, _} = Vaults.put_member(ctx.vault, viewer, :viewer)
    restore = versions(ctx) <> "/#{ctx.oldest.id}/restore"

    assert ctx.conn |> as(viewer) |> post(restore) |> json_response(403)
    assert ctx.conn |> as(ctx.owner) |> post(restore) |> json_response(200)
    assert Sync.text(ctx.note.id) == "the quick fox\n"
  end

  test "strangers and other vaults' notes get nothing", ctx do
    stranger = user()
    assert ctx.conn |> as(stranger) |> get(versions(ctx)) |> json_response(403)

    elsewhere = entry(vault(ctx.owner), "b.md")
    path = ~p"/api/vaults/#{ctx.vault.id}/notes/#{elsewhere.id}/versions"
    assert ctx.conn |> as(ctx.owner) |> get(path) |> json_response(404)
    assert ctx.conn |> as(ctx.owner) |> get(versions(ctx) <> "/999999") |> json_response(404)
  end
end
