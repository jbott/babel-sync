defmodule BabelSyncWeb.ExportControllerTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.{Blobs, Sync, Vaults}

  test "a vault comes down as the files Obsidian would have", %{conn: conn} do
    vault = vault(BabelSync.Accounts.single_user!(), %{name: "Field notes"})
    note = entry(vault, "Trips/Lisbon.md")
    :ok = Sync.replace_text(note.id, "Five days in Alfama.")
    {:ok, blob} = Blobs.put(vault.id, "png bytes")

    {:ok, _} =
      Vaults.create_entry(vault.id, %{
        path: "pic.png",
        kind: :blob,
        blob_hash: blob.hash,
        size: blob.size
      })

    {:ok, _} = Vaults.create_entry(vault.id, %{path: "Empty", kind: :folder})
    {:ok, [_]} = vault |> entry("gone.md") |> Vaults.delete_entry()

    response = get(conn, ~p"/v/#{vault.id}/export")
    assert response.status == 200
    assert [disposition] = get_resp_header(response, "content-disposition")
    assert disposition =~ ~s(filename="Field notes.zip")

    {:ok, files} = :zip.unzip(response.resp_body, [:memory])

    assert Map.new(files, fn {name, data} -> {List.to_string(name), data} end) == %{
             "Empty/" => "",
             "Trips/Lisbon.md" => "Five days in Alfama.",
             "pic.png" => "png bytes"
           }
  end

  test "someone without access gets nothing", %{conn: conn} do
    with_auth([:passkey])
    vault = vault(user())
    assert conn |> get(~p"/v/#{vault.id}/export") |> response(404)
  end
end
