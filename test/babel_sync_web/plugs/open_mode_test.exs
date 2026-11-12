defmodule BabelSyncWeb.Plugs.OpenModeTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures

  alias BabelSyncWeb.Plugs.Secure

  test "with sign-in off, a request naming another host gets nothing", %{conn: conn} do
    vault = vault(BabelSync.Accounts.single_user!())
    note = "/v/#{vault.id}/raw/a.md"
    entry(vault, "a.md")
    assert conn |> get(~p"/api/vaults") |> json_response(200)
    assert conn |> get(note) |> response(200)

    rebound = %{conn | host: "attacker.example"}
    assert rebound |> get(~p"/api/vaults") |> json_response(401)
    refute rebound |> get(note) |> Map.get(:status) == 200
  end

  describe "https" do
    setup do
      previous = BabelSyncWeb.Endpoint.config(:url)
      url = Keyword.merge(previous, host: "notes.example.com", scheme: "https", port: 443)
      Application.put_env(:babel_sync, BabelSyncWeb.Endpoint, Keyword.put(endpoint(), :url, url))
      BabelSyncWeb.Endpoint.config_change([{BabelSyncWeb.Endpoint, endpoint()}], [])

      on_exit(fn ->
        Application.put_env(
          :babel_sync,
          BabelSyncWeb.Endpoint,
          Keyword.put(endpoint(), :url, previous)
        )

        BabelSyncWeb.Endpoint.config_change([{BabelSyncWeb.Endpoint, endpoint()}], [])
      end)
    end

    defp endpoint, do: Application.get_env(:babel_sync, BabelSyncWeb.Endpoint)

    defp secure(conn), do: Secure.call(conn, Secure.init([]))

    test "plain http is sent to the https address" do
      conn = Plug.Test.conn(:get, "http://notes.example.com/") |> secure()
      assert conn.halted
      assert get_resp_header(conn, "location") == ["https://notes.example.com/"]
    end

    test "a forwarded scheme is believed from a proxy on this machine only" do
      proxied =
        Plug.Test.conn(:get, "http://notes.example.com/")
        |> put_req_header("x-forwarded-proto", "https")

      refute secure(%{proxied | remote_ip: {127, 0, 0, 1}}).halted
      assert secure(%{proxied | remote_ip: {192, 168, 1, 20}}).halted
    end
  end
end
