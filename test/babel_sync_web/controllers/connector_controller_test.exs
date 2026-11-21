defmodule BabelSyncWeb.ConnectorControllerTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Accounts.Scope
  alias BabelSync.Connectors.Session
  alias BabelSync.{Connectors, Repo}

  @host "fixture.example"
  @url "https://fixture.example/account"
  @cookie "fixture-session"
  @rotated "rotated-session"
  @quoted_cookie ~s("#{@cookie}")
  @quoted_rotated ~s("#{@rotated}")
  @agent "Fixture Chrome"

  setup do
    with_auth([:passkey])
    previous = Application.get_env(:babel_sync, :connector_adapter)
    Application.put_env(:babel_sync, :connector_adapter, __MODULE__)

    on_exit(fn ->
      Application.delete_env(:babel_sync, __MODULE__)

      if previous,
        do: Application.put_env(:babel_sync, :connector_adapter, previous),
        else: Application.delete_env(:babel_sync, :connector_adapter)
    end)

    owner = user()
    vault = vault(owner)
    id = Ecto.UUID.generate()
    %{owner: owner, vault: vault, id: id, path: "/api/vaults/#{vault.id}/connections/#{id}"}
  end

  test "handoff seals the jar and rejected replacement preserves the working session", ctx do
    assert %{"status" => "connected"} =
             ctx.conn |> bearer(ctx.owner) |> post(ctx.path, payload()) |> json_response(200)

    session = Repo.get_by!(Session, vault_id: ctx.vault.id, connection_id: ctx.id)
    assert is_binary(session.sealed)
    refute session.sealed =~ @cookie
    refute inspect(session) =~ session.sealed

    assert %{"error" => "reauthorize"} =
             ctx.conn
             |> bearer(ctx.owner)
             |> post(ctx.path, payload("rejected"))
             |> json_response(422)

    assert Repo.get!(Session, session.id).sealed == session.sealed
    scope = Scope.for_user(ctx.owner)

    assert {:ok, %{status: 200, body: body}} =
             Connectors.request(scope, ctx.vault.id, ctx.id, %{url: @url}, hosts: [@host])

    assert body =~ "Signed in"
    assert body =~ "[secret]"
    assert Repo.get!(Session, session.id).revision == session.revision

    assert %{"status" => "connected"} =
             ctx.conn |> bearer(ctx.owner) |> get(ctx.path) |> json_response(200)

    assert {:error, :forbidden} =
             Connectors.request(scope, ctx.vault.id, ctx.id, %{url: @url},
               hosts: ["other.example"]
             )

    assert {:error, :forbidden} =
             Connectors.request(
               scope,
               ctx.vault.id,
               ctx.id,
               %{url: "https://other.example/account"},
               hosts: ["other.example"]
             )
  end

  test "rotated cookies stay on the server and reflected credentials are redacted", ctx do
    assert ctx.conn |> bearer(ctx.owner) |> post(ctx.path, payload()) |> json_response(200)
    scope = Scope.for_user(ctx.owner)

    assert {:ok, %{body: body, headers: headers}} =
             Connectors.request(
               scope,
               ctx.vault.id,
               ctx.id,
               %{url: "https://fixture.example/rotate"},
               hosts: [@host]
             )

    assert body == "[secret] [secret] 1"
    refute Map.has_key?(headers, "set-cookie")
    assert headers["x-echo"] == "[secret]"

    assert {:ok, %{body: "fresh"}} =
             Connectors.request(
               scope,
               ctx.vault.id,
               ctx.id,
               %{url: "https://fixture.example/records"},
               hosts: [@host]
             )
  end

  test "quoted sessions connect, rotate verbatim and redact both reflected forms", ctx do
    assert %{"status" => "connected"} =
             ctx.conn
             |> bearer(ctx.owner)
             |> post(ctx.path, payload(@quoted_cookie))
             |> json_response(200)

    scope = Scope.for_user(ctx.owner)

    assert {:ok, %{body: body, headers: headers}} =
             Connectors.request(
               scope,
               ctx.vault.id,
               ctx.id,
               %{url: "https://fixture.example/rotate"},
               hosts: [@host]
             )

    assert body == "[secret] [secret] [secret] [secret] 1"
    assert headers["x-echo"] == "[secret] [secret]"
    refute Map.has_key?(headers, "set-cookie")

    assert {:ok, %{body: "fresh"}} =
             Connectors.request(
               scope,
               ctx.vault.id,
               ctx.id,
               %{url: "https://fixture.example/records"},
               hosts: [@host]
             )
  end

  test "handoff and disconnect require an admin credential for the target vault", ctx do
    assert ctx.conn |> post(ctx.path, payload()) |> json_response(401)
    assert ctx.conn |> bearer(user()) |> post(ctx.path, payload()) |> json_response(403)

    assert ctx.conn
           |> bearer(ctx.owner, read_only: true)
           |> post(ctx.path, payload())
           |> json_response(403)

    other_vault = vault(user())
    other_path = "/api/vaults/#{other_vault.id}/connections/#{ctx.id}"
    assert ctx.conn |> bearer(ctx.owner) |> post(other_path, payload()) |> json_response(403)
    assert Repo.all(Session) == []

    assert ctx.conn |> bearer(ctx.owner) |> post(ctx.path, payload()) |> json_response(200)
    assert ctx.conn |> bearer(user()) |> delete(ctx.path) |> json_response(403)

    assert ctx.conn
           |> bearer(ctx.owner, read_only: true)
           |> delete(ctx.path)
           |> json_response(403)

    assert %{"status" => "disconnected"} =
             ctx.conn |> bearer(ctx.owner) |> delete(ctx.path) |> json_response(200)

    assert {:error, :reauthorize} =
             Connectors.request(Scope.for_user(ctx.owner), ctx.vault.id, ctx.id, %{url: @url},
               hosts: [@host]
             )
  end

  test "disconnect during candidate verification prevents restoring access", ctx do
    assert ctx.conn |> bearer(ctx.owner) |> post(ctx.path, payload()) |> json_response(200)

    Application.put_env(:babel_sync, __MODULE__, fn _request ->
      assert :ok = Connectors.disconnect(Scope.for_user(ctx.owner), ctx.vault.id, ctx.id)
    end)

    assert %{"error" => "changed"} =
             ctx.conn |> bearer(ctx.owner) |> post(ctx.path, payload()) |> json_response(409)

    assert Repo.get_by!(Session, vault_id: ctx.vault.id, connection_id: ctx.id).sealed == nil
  end

  defp payload(value \\ @cookie) do
    %{
      "name" => "Fixture account",
      "landing_url" => @url,
      "hosts" => [@host],
      "check_selector" => ~s|#account[data-user="#{@cookie}"]|,
      "user_agent" => @agent,
      "cookies" => [
        %{
          "name" => "session",
          "value" => value,
          "domain" => @host,
          "path" => "/",
          "hostOnly" => true,
          "httpOnly" => true
        },
        %{
          "name" => "preference",
          "value" => "1",
          "domain" => @host,
          "path" => "/",
          "hostOnly" => true,
          "httpOnly" => false
        }
      ]
    }
  end

  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t()}
  def run(request) do
    if action = Application.get_env(:babel_sync, __MODULE__), do: action.(request)
    assert request.url.host == @host
    assert request.url.scheme == "https"
    assert request.method == :get
    assert Req.Request.get_header(request, "user-agent") == [@agent]

    cookies =
      request |> Req.Request.get_header("cookie") |> Enum.join("; ") |> Plug.Conn.Cookies.decode()

    {body, headers} =
      case {cookies["session"], request.url.path} do
        {value, "/account"} when value in [@cookie, @quoted_cookie] ->
          {~s|<main id="account" data-user="#{@cookie}">Signed in</main>|, %{}}

        {@cookie, "/rotate"} ->
          {"#{@cookie} #{@rotated} 1",
           %{"set-cookie" => ["session=#{@rotated}; Path=/; HttpOnly"], "x-echo" => [@cookie]}}

        {@quoted_cookie, "/rotate"} ->
          {"#{@quoted_cookie} #{@cookie} #{@quoted_rotated} #{@rotated} 1",
           %{
             "set-cookie" => ["session=#{@quoted_rotated}; Path=/; HttpOnly"],
             "x-echo" => ["#{@quoted_cookie} #{@cookie}"]
           }}

        {value, "/records"} when value in [@rotated, @quoted_rotated] ->
          {"fresh", %{}}

        _other ->
          {~s|<form id="signin"></form>|, %{}}
      end

    {request, %Req.Response{status: 200, headers: headers, body: body}}
  end
end
