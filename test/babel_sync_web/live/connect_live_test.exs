defmodule BabelSyncWeb.ConnectLiveTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures
  import Phoenix.LiveViewTest

  alias BabelSync.Obsidian.Plugin
  alias BabelSync.Vaults
  alias BabelSyncWeb.Paths

  setup %{conn: conn} do
    owner = user()
    vault = vault(owner, %{name: "Research"})
    %{conn: sign_in(conn, owner), anonymous: conn, owner: owner, vault: vault}
  end

  test "names the vault and leads back to it", %{conn: conn, vault: vault} do
    {:ok, view, _html} = live(conn, Paths.connect(vault.id))

    assert has_element?(view, "#connect-vault", "Research")
    assert has_element?(view, "#connect-back[href='#{Paths.vault(vault.id)}']")
    assert has_element?(view, "#connect-devices-link[href='/account?from=#{vault.id}#grants']")
  end

  test "is open to someone who may only read the vault", %{anonymous: conn, vault: vault} do
    Application.put_env(:babel_sync, :mode, :multi)
    on_exit(fn -> Application.put_env(:babel_sync, :mode, :single) end)

    viewer = user()
    {:ok, _member} = Vaults.put_member(vault, viewer, :viewer)
    {:ok, view, _html} = conn |> sign_in(viewer) |> live(Paths.connect(vault.id))

    assert has_element?(view, "#connect-vault", "Research")
  end

  test "refuses a vault that is unknown or someone else's", %{anonymous: conn, vault: vault} do
    Application.put_env(:babel_sync, :mode, :multi)
    on_exit(fn -> Application.put_env(:babel_sync, :mode, :single) end)

    stranger = sign_in(conn, user())

    for id <- [vault.id, Ecto.UUID.generate(), "nonsense"] do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(stranger, Paths.connect(id))
    end
  end

  test "offers one link that opens Obsidian on this vault", %{conn: conn, vault: vault} do
    {:ok, view, _html} = live(conn, Paths.connect(vault.id))

    href =
      view
      |> element("#step-2 a#connect-open-obsidian")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("href")
      |> hd()

    assert "obsidian://babelsync-connect?" <> query = href

    assert URI.decode_query(query) == %{
             "server" => BabelSyncWeb.Endpoint.url(),
             "id" => vault.id,
             "name" => "Research"
           }

    refute has_element?(view, "#connect-open-obsidian[data-phx-link]")
    assert has_element?(view, "#merge-caution", "Research")
  end

  test "assumes the plugin is there and keeps installing it out of the way", %{
    conn: conn,
    vault: vault
  } do
    {:ok, view, _html} = live(conn, Paths.connect(vault.id))

    assert has_element?(view, "#plugin-ready[aria-current]")
    assert has_element?(view, "#plugin-ready-note")
    refute has_element?(view, "#install")

    view |> element("#plugin-install") |> render_click()

    assert_patch(view, Paths.connect(vault.id) <> "?device=iphone&plugin=install")
    assert has_element?(view, "#plugin-install[aria-current]")
    assert has_element?(view, "#install", "community directory")
    assert has_element?(view, "#connect-open-obsidian")
  end

  test "installing offers both downloads when the server carries the plugin", %{
    conn: conn,
    vault: vault
  } do
    {:ok, view, _html} = live(conn, Paths.connect(vault.id) <> "?plugin=install")

    if Plugin.available?() do
      assert has_element?(
               view,
               "#install-new a#download-vault[download][href$='/v/#{vault.id}/obsidian/vault.zip']"
             )

      assert has_element?(
               view,
               "#install-existing a#download-plugin[download][href='/obsidian/plugin.zip']"
             )

      refute has_element?(view, "#plugin-unavailable")
    else
      assert has_element?(view, "#plugin-unavailable", "mix plugin.build")
      refute has_element?(view, "#download-vault")
      refute has_element?(view, "#download-plugin")
    end

    assert has_element?(view, "#install-existing-steps", ".obsidian/plugins")
  end

  test "says where the vault folder goes on each kind of device", %{conn: conn, vault: vault} do
    for {device, words} <- [
          {"iphone", "On My iPhone"},
          {"android", "Documents › Obsidian"},
          {"computer", "Open folder as vault"}
        ] do
      {:ok, view, _html} =
        live(conn, Paths.connect(vault.id) <> "?plugin=install&device=#{device}")

      assert has_element?(view, "#device-#{device}[aria-current]")
      assert has_element?(view, "#install-new-steps", words)
      assert has_element?(view, "#install-new-steps", "Trust author and enable plugins")
    end

    {:ok, view, _html} = live(conn, Paths.connect(vault.id) <> "?plugin=install")
    view |> element("#device-android") |> render_click()

    assert_patch(view, Paths.connect(vault.id) <> "?device=android&plugin=install")
    assert has_element?(view, "#device-android[aria-current]")
  end

  test "picks the device from the browser that asks", %{conn: conn, vault: vault} do
    for {agent, device} <- [
          {"Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X)", "iphone"},
          {"Mozilla/5.0 (Linux; Android 15; Pixel 9)", "android"},
          {"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", "computer"}
        ] do
      {:ok, view, _html} =
        conn
        |> put_req_header("user-agent", agent)
        |> live(Paths.connect(vault.id) <> "?plugin=install")

      assert has_element?(view, "#device-#{device}[aria-current]")
    end
  end

  test "ignores choices it does not know", %{conn: conn, vault: vault} do
    {:ok, view, _html} = live(conn, Paths.connect(vault.id) <> "?plugin=maybe&device=toaster")

    assert has_element?(view, "#plugin-ready[aria-current]")
    refute has_element?(view, "#install")
  end

  test "gives the server address for connecting by hand", %{conn: conn, vault: vault} do
    {:ok, view, _html} = live(conn, Paths.connect(vault.id))

    assert has_element?(
             view,
             "#trouble #server-address[readonly][value='#{BabelSyncWeb.Endpoint.url()}']"
           )

    assert has_element?(view, "#copy-server-address[data-copy='#{BabelSyncWeb.Endpoint.url()}']")
  end

  test "the vault page leads here from its empty state, tree and switcher", %{
    conn: conn,
    vault: vault
  } do
    {:ok, view, _html} = live(conn, Paths.vault(vault.id))

    assert has_element?(view, "#empty a#connect-obsidian[href='#{Paths.connect(vault.id)}']")
    assert has_element?(view, "#tree a#tree-connect[href='#{Paths.connect(vault.id)}']")

    view |> element("#vault-switcher-form") |> render_change(%{"vault" => "connect"})
    assert_redirect(view, Paths.connect(vault.id))
  end

  test "settings offer to connect a device to the vault the person came from", %{
    conn: conn,
    owner: owner,
    vault: vault
  } do
    journal = vault(owner, %{name: "Journal"})

    {:ok, account, _html} = live(conn, ~p"/account?from=#{journal.id}")
    assert has_element?(account, "#grants a#connect-device[href='#{Paths.connect(journal.id)}']")

    first = owner |> Vaults.list_vaults() |> hd()
    assert first.id in [journal.id, vault.id]

    {:ok, account, _html} = live(conn, ~p"/account")
    assert has_element?(account, "#grants a#connect-device[href='#{Paths.connect(first.id)}']")
  end

  test "settings offer no device to connect without a vault", %{anonymous: conn} do
    {:ok, account, _html} = conn |> sign_in(user()) |> live(~p"/account")

    refute has_element?(account, "#connect-device")
  end
end
