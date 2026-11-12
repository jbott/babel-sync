defmodule BabelSyncWeb.DocControllerTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Auth, Sync}

  setup %{conn: conn} do
    owner = user()
    vault = vault(owner)
    note = entry(vault, "a.md")
    :ok = Sync.replace_text(note.id, "hello")
    %{conn: conn, owner: owner, vault: vault, note: note}
  end

  defp as(conn, user),
    do:
      put_req_header(conn, "authorization", "Bearer " <> Auth.socket_token(Scope.for_user(user)))

  test "a member gets the stored updates of the notes asked for", ctx do
    docs =
      ctx.conn
      |> as(ctx.owner)
      |> post(~p"/api/vaults/#{ctx.vault.id}/docs", %{ids: [ctx.note.id]})
      |> json_response(200)
      |> Map.fetch!("docs")

    updates = docs |> Map.fetch!(ctx.note.id) |> Enum.map(&Base.decode64!/1)
    doc = Yex.Doc.new()
    Enum.each(updates, &Yex.apply_update(doc, &1))
    assert doc |> Yex.Doc.get_text("content") |> Yex.Text.to_string() == "hello"
  end

  test "notes from other vaults and strangers get nothing", ctx do
    elsewhere = entry(vault(ctx.owner), "b.md")

    assert %{"docs" => docs} =
             ctx.conn
             |> as(ctx.owner)
             |> post(~p"/api/vaults/#{ctx.vault.id}/docs", %{ids: [elsewhere.id]})
             |> json_response(200)

    assert docs == %{}

    assert ctx.conn
           |> as(user())
           |> post(~p"/api/vaults/#{ctx.vault.id}/docs", %{ids: [ctx.note.id]})
           |> json_response(403)
  end
end
