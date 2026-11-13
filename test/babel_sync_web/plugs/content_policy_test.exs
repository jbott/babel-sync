defmodule BabelSyncWeb.Plugs.ContentPolicyTest do
  use BabelSyncWeb.ConnCase, async: false

  setup do
    with_auth([:passkey])
  end

  test "pages allow script only from the server and the layout's own nonce", %{conn: conn} do
    conn = get(conn, ~p"/login")
    [policy] = get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, policy)

    assert policy =~ "script-src 'self' 'nonce-"
    assert policy =~ "frame-ancestors 'none'"

    scripts =
      conn
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("script:not([src])")

    assert scripts |> LazyHTML.attribute("nonce") |> Enum.uniq() == [nonce]
  end

  test "each response gets a fresh nonce", %{conn: conn} do
    policies =
      for _ <- 1..2,
          do: conn |> get(~p"/login") |> get_resp_header("content-security-policy") |> hd()

    assert Enum.uniq(policies) |> length() == 2
  end
end
