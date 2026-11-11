defmodule BabelSyncWeb.ObsidianControllerTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Obsidian.Plugin

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    File.write!(Path.join(directory, "main.js"), "module.exports = {}")
    File.write!(Path.join(directory, "manifest.json"), ~s({"id":"babelsync","version":"9.9.9"}))
    built(directory)
  end

  defp built(directory) do
    previous = Application.get_env(:babel_sync, Plugin, [])
    Application.put_env(:babel_sync, Plugin, directory: directory)
    on_exit(fn -> Application.put_env(:babel_sync, Plugin, previous) end)
  end

  defp files(conn) do
    {:ok, entries} = :zip.unzip(response(conn, 200), [:memory])
    Map.new(entries, fn {name, data} -> {List.to_string(name), data} end)
  end

  test "the plugin alone unpacks to a folder Obsidian can load", %{conn: conn} do
    conn = get(conn, ~p"/obsidian/plugin.zip")

    assert %{"babelsync/main.js" => "module.exports = {}", "babelsync/manifest.json" => _manifest} =
             files(conn)

    assert get_resp_header(conn, "content-disposition") |> hd() =~ "babelsync-plugin.zip"
    assert Plugin.version() == "9.9.9"
    assert Plugin.build() =~ ~r/^[0-9a-f]{8}$/
  end

  test "a starter vault has the plugin on and pointed at the vault", %{conn: conn} do
    vault = vault(user(), %{name: "Field: Notes"})
    conn = get(conn, ~p"/v/#{vault.id}/obsidian/vault.zip")
    files = files(conn)
    plugin = "Field Notes/.obsidian/plugins/babelsync/"

    assert Jason.decode!(files["Field Notes/.obsidian/community-plugins.json"]) == ["babelsync"]
    assert files[plugin <> "main.js"] == "module.exports = {}"

    assert Jason.decode!(files[plugin <> "data.json"]) == %{
             "serverUrl" => BabelSyncWeb.Endpoint.url(),
             "vaultId" => vault.id,
             "vaultName" => "Field: Notes"
           }

    assert get_resp_header(conn, "content-disposition") |> hd() =~ "Field%20Notes.zip"
  end

  test "a vault name that cannot be a folder still gets one" do
    assert Plugin.folder_name("  ../..  ") == "Babel Sync vault"
    assert Plugin.folder_name("a/b\\c") == "a b c"
  end

  test "only people who can read a vault get its starter", %{conn: conn} do
    with_auth([:passkey])
    owner = user()
    vault = vault(owner)

    assert conn |> sign_in(user()) |> get(~p"/v/#{vault.id}/obsidian/vault.zip") |> response(404)
    assert conn |> sign_in(owner) |> get(~p"/v/#{vault.id}/obsidian/vault.zip") |> response(200)
    assert conn |> sign_in(owner) |> get(~p"/v/not-a-vault/obsidian/vault.zip") |> response(404)
  end

  test "nothing is handed out to someone who is not signed in", %{conn: conn} do
    with_auth([:passkey])

    refute get(conn, ~p"/obsidian/plugin.zip").status == 200
  end

  test "a server built without the plugin says so", %{conn: conn, tmp_dir: directory} do
    File.rm!(Path.join(directory, "main.js"))

    refute Plugin.available?()
    assert conn |> get(~p"/obsidian/plugin.zip") |> response(404)
  end
end
