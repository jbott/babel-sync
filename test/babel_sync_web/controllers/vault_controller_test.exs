defmodule BabelSyncWeb.VaultControllerTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Accounts.Scope
  alias BabelSync.{Auth, Vaults}

  defp as(conn, user) do
    token = user |> Scope.for_user() |> Auth.socket_token()
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  test "lists the vaults a user belongs to with their role", %{conn: conn} do
    owner = user()
    guest = user()
    mine = vault(owner)
    _other = vault(user())
    {:ok, _member} = Vaults.put_member(mine, guest, :viewer)

    assert %{"vaults" => [%{"id" => id, "name" => name, "role" => "owner"}]} =
             conn |> as(owner) |> get("/api/vaults") |> json_response(200)

    assert {id, name} == {mine.id, mine.name}

    entry(mine, "a.md")
    entry(mine, "Folder", %{kind: :folder})
    entry(mine, ".obsidian/app.json")

    assert %{"vaults" => [%{"files" => 1}]} =
             conn |> as(owner) |> get("/api/vaults") |> json_response(200)

    assert %{"vaults" => [%{"id" => ^id, "role" => "viewer"}]} =
             conn |> as(guest) |> get("/api/vaults") |> json_response(200)
  end
end
