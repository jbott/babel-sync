defmodule BabelSyncWeb.Plugs.Scope do
  @moduledoc """
  Resolves who is making an HTTP request: a bearer token, the browser
  session, or the owner when single-user sign-in is disabled.

  A bearer token has to be attached on purpose, so it is honoured from
  any origin. The session cookie and the open single-user mode are
  ambient, so requests relying on them must not come from another site.

  A browser session lasts 30 days from its last use, not from sign-in:
  once a day, a request made with a valid session is answered with a
  freshly dated one.

  The cookie names a row in the sessions table, so a session can be
  listed and ended from another browser. A cookie from before that
  table existed is exchanged for a row the first time it is seen.
  """

  import Plug.Conn

  alias BabelSync.Accounts.{Session, Sessions}
  alias BabelSync.Auth
  alias BabelSyncWeb.Origin

  @session_key "scope_token"
  @prolonged_key "scope_prolonged"
  @prolong_after 86_400

  def session_key, do: @session_key

  def fetch_scope(conn, _opts) do
    result =
      case bearer(conn) do
        nil -> if foreign?(conn), do: :error, else: Auth.scope_from_session(session_token(conn))
        token -> Auth.scope_from_token(token)
      end

    case result do
      {:ok, scope} -> conn |> assign(:current_scope, scope) |> prolong(scope)
      :error -> assign(conn, :current_scope, nil)
    end
  end

  @doc """
  Starts a browser session for the user and names it in the cookie.
  """
  def sign_in(conn, user) do
    agent = conn |> get_req_header("user-agent") |> List.first("")
    session = Sessions.start(user, agent)

    conn
    |> put_session(@session_key, Auth.session_token(session))
    |> put_session(@prolonged_key, System.system_time(:second))
    |> put_session(:live_socket_id, Sessions.topic(session.id))
  end

  @doc """
  Ends the browser session the request came with.
  """
  def sign_out(conn) do
    with %{user: user, session_id: id} when is_binary(id) <- conn.assigns[:current_scope] do
      Sessions.finish(user, id)
    end

    configure_session(conn, drop: true)
  end

  defp prolong(conn, %{user: user, session_id: id}) do
    now = System.system_time(:second)

    cond do
      bearer(conn) != nil or session_token(conn) == nil or Auth.open?() ->
        conn

      id == nil ->
        sign_in(conn, user)

      due?(conn, now) ->
        Sessions.seen(id)

        conn
        |> put_session(@session_key, Auth.session_token(%Session{id: id}))
        |> put_session(@prolonged_key, now)

      true ->
        conn
    end
  end

  defp due?(conn, now) do
    case get_session(conn, @prolonged_key) do
      at when is_integer(at) -> now - at >= @prolong_after
      _never -> true
    end
  end

  def require_scope(%{assigns: %{current_scope: nil}} = conn, _opts) do
    metadata = BabelSyncWeb.Endpoint.url() <> "/.well-known/oauth-protected-resource"

    conn
    |> put_resp_header("www-authenticate", ~s(Bearer resource_metadata="#{metadata}"))
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{error: "unauthorized"})
    |> halt()
  end

  def require_scope(conn, _opts), do: conn

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _none -> nil
    end
  end

  defp foreign?(conn) do
    case get_req_header(conn, "origin") do
      [origin] -> not Origin.allowed?(URI.parse(origin))
      _none -> false
    end
  end

  defp session_token(%{private: %{plug_session: session}}), do: session[@session_key]
  defp session_token(_conn), do: nil
end
