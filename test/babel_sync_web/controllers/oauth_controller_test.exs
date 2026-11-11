defmodule BabelSyncWeb.OAuthControllerTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures
  import Phoenix.LiveViewTest

  alias BabelSync.Accounts

  @verifier "a-verifier-that-is-long-enough-to-be-plausible-0123456789"
  @redirect "http://127.0.0.1:9876/callback"

  defp register(conn, redirect_uris \\ [@redirect]) do
    conn
    |> post(~p"/oauth/register", %{client_name: "Research agent", redirect_uris: redirect_uris})
    |> json_response(201)
  end

  defp authorize_params(client_id, extra \\ %{}) do
    Map.merge(
      %{
        client_id: client_id,
        redirect_uri: @redirect,
        response_type: "code",
        state: "st",
        code_challenge: Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false),
        code_challenge_method: "S256"
      },
      extra
    )
  end

  defp query_of(conn),
    do: conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp tokens(conn, client_id, code) do
    conn
    |> post(~p"/oauth/token", %{
      grant_type: "authorization_code",
      code: code,
      client_id: client_id,
      redirect_uri: @redirect,
      code_verifier: @verifier
    })
    |> json_response(200)
  end

  test "metadata points clients at the endpoints", %{conn: conn} do
    base = BabelSyncWeb.Endpoint.url()

    assert %{
             "issuer" => ^base,
             "authorization_endpoint" => authorize,
             "registration_endpoint" => _register,
             "code_challenge_methods_supported" => ["S256"]
           } = conn |> get("/.well-known/oauth-authorization-server") |> json_response(200)

    assert authorize == base <> "/oauth/authorize"

    assert %{"authorization_servers" => [^base], "resource" => resource} =
             conn |> get("/.well-known/oauth-protected-resource/mcp") |> json_response(200)

    assert resource == base <> "/mcp"
  end

  test "registration refuses unsafe redirect addresses", %{conn: conn} do
    assert %{"error" => "invalid_redirect_uri"} =
             conn
             |> post(~p"/oauth/register", %{
               client_name: "x",
               redirect_uris: ["http://evil.example/cb"]
             })
             |> json_response(400)
  end

  test "an agent is approved, uses its token over MCP and the API, and is disconnected", %{
    conn: conn
  } do
    with_auth([:passkey])
    owner = Accounts.single_user!()
    vault = vault(owner)
    %{"client_id" => client_id} = register(conn)

    unauthorized = post(conn, "/mcp", %{})
    assert json_response(unauthorized, 401)
    assert [challenge] = get_resp_header(unauthorized, "www-authenticate")
    assert challenge =~ "/.well-known/oauth-protected-resource"

    bounced = get(conn, ~p"/oauth/authorize", authorize_params(client_id))
    assert redirected_to(bounced) == "/login"

    browser = sign_in(conn, owner)
    consent = get(browser, ~p"/oauth/authorize", authorize_params(client_id))
    page = html_response(consent, 200)
    document = LazyHTML.from_document(page)
    assert LazyHTML.text(LazyHTML.query(document, "#consent-client")) =~ "Research agent"
    assert LazyHTML.text(LazyHTML.query(document, "#consent-access")) =~ "read and change"

    approved =
      post(
        browser,
        ~p"/oauth/authorize",
        Map.put(authorize_params(client_id), :decision, "approve")
      )

    assert %{"code" => code, "state" => "st"} = query_of(approved)

    assert %{"access_token" => access, "refresh_token" => refresh, "expires_in" => 3600} =
             tokens(conn, client_id, code)

    api = put_req_header(conn, "authorization", "Bearer " <> access)
    assert %{"vaults" => [%{"id" => id}]} = api |> get(~p"/api/vaults") |> json_response(200)
    assert id == vault.id

    assert %{"access_token" => rotated} =
             conn
             |> post(~p"/oauth/token", %{
               grant_type: "refresh_token",
               refresh_token: refresh,
               client_id: client_id
             })
             |> json_response(200)

    assert api |> get(~p"/api/vaults") |> json_response(401)

    {:ok, account, _html} = live(browser, ~p"/account")
    assert has_element?(account, "#grants li", "Research agent")
    account |> element("#grants li button") |> render_click()
    refute has_element?(account, "#grants li", "Research agent")

    assert conn
           |> put_req_header("authorization", "Bearer " <> rotated)
           |> get(~p"/api/vaults")
           |> json_response(401)
  end

  test "declining sends the app an error and no code", %{conn: conn} do
    %{"client_id" => client_id} = register(conn)

    denied =
      post(conn, ~p"/oauth/authorize", Map.put(authorize_params(client_id), :decision, "deny"))

    assert %{"error" => "access_denied", "state" => "st"} = query_of(denied)
  end

  test "a read-only request is described as such", %{conn: conn} do
    %{"client_id" => client_id} = register(conn)
    consent = get(conn, ~p"/oauth/authorize", authorize_params(client_id, %{scope: "vault:read"}))
    document = consent |> html_response(200) |> LazyHTML.from_document()
    access = LazyHTML.text(LazyHTML.query(document, "#consent-access"))
    assert access =~ "read"
    refute access =~ "change"
  end

  test "an unknown app or a redirect it did not register is shown an error page", %{conn: conn} do
    %{"client_id" => client_id} = register(conn)

    for params <- [
          authorize_params(Ecto.UUID.generate()),
          authorize_params(client_id, %{redirect_uri: "https://evil.example/cb"})
        ] do
      refused = get(conn, ~p"/oauth/authorize", params)
      document = refused |> html_response(400) |> LazyHTML.from_document()
      assert LazyHTML.query(document, "#oauth-invalid") |> Enum.count() == 1
    end
  end

  test "token errors are reported as oauth errors", %{conn: conn} do
    assert %{"error" => "invalid_grant"} =
             conn
             |> post(~p"/oauth/token", %{grant_type: "authorization_code", code: "bsc_nope"})
             |> json_response(400)

    assert %{"error" => "unsupported_grant_type"} =
             conn |> post(~p"/oauth/token", %{grant_type: "password"}) |> json_response(400)
  end

  describe "requests from other sites" do
    test "cannot ride on the open single-user mode", %{conn: conn} do
      assert conn |> get(~p"/api/vaults") |> json_response(200)

      assert conn
             |> put_req_header("origin", "https://evil.example")
             |> get(~p"/api/vaults")
             |> json_response(401)

      assert conn
             |> put_req_header("origin", "https://evil.example")
             |> post("/mcp", %{})
             |> json_response(401)

      assert conn
             |> put_req_header("origin", "app://obsidian.md")
             |> get(~p"/api/vaults")
             |> json_response(200)
    end

    test "may still present a token", %{conn: conn} do
      owner = Accounts.single_user!()

      assert conn
             |> put_req_header("origin", "https://agent.example")
             |> bearer(owner)
             |> get(~p"/api/vaults")
             |> json_response(200)
    end

    test "get permissive cross-origin headers only on token-based endpoints", %{conn: conn} do
      preflight = options(conn, "/oauth/token")
      assert response(preflight, 204)
      assert get_resp_header(preflight, "access-control-allow-origin") == ["*"]

      assert conn |> get(~p"/api/vaults") |> get_resp_header("access-control-allow-origin") == []
    end
  end
end
