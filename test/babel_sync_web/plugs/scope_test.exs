defmodule BabelSyncWeb.Plugs.ScopeTest do
  use BabelSyncWeb.ConnCase, async: false

  import BabelSync.Fixtures

  alias BabelSync.Auth
  alias BabelSyncWeb.Plugs.Scope

  defp visit(conn, session) do
    conn |> Plug.Test.init_test_session(session) |> get(~p"/")
  end

  setup do
    with_auth([:passkey])
    :ok
  end

  defp cookie(conn), do: conn.resp_cookies["_babel_sync_key"]

  test "a session in use is dated afresh once a day, so it does not run out", %{conn: conn} do
    token = Auth.session_token(user())
    now = System.system_time(:second)

    first = visit(conn, %{Scope.session_key() => token})
    assert %{max_age: 2_592_000} = cookie(first)
    assert_in_delta get_session(first, "scope_prolonged"), now, 5

    recent = visit(conn, %{Scope.session_key() => token, "scope_prolonged" => now - 3600})
    assert get_session(recent, "scope_prolonged") == now - 3600

    day_old = visit(conn, %{Scope.session_key() => token, "scope_prolonged" => now - 90_000})
    assert %{max_age: 2_592_000} = cookie(day_old)
    assert {:ok, _scope} = Auth.scope_from_session(get_session(day_old, Scope.session_key()))
  end

  test "a server that needs no sign-in has no session to prolong", %{conn: conn} do
    with_auth([])
    open = visit(conn, %{Scope.session_key() => Auth.session_token(user())})
    assert get_session(open, "scope_prolonged") == nil
  end

  test "a visitor who is not signed in is given nothing to keep", %{conn: conn} do
    stranger = visit(conn, %{})
    assert get_session(stranger, "scope_prolonged") == nil

    forged = visit(conn, %{Scope.session_key() => "not a token"})
    assert get_session(forged, "scope_prolonged") == nil
  end
end
