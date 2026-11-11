defmodule BabelSyncWeb.Plugs.Scope do
  @moduledoc """
  Resolves who is making an HTTP request: a bearer token, the browser
  session, or the owner when single-user sign-in is disabled.

  A bearer token has to be attached on purpose, so it is honoured from
  any origin. The session cookie and the open single-user mode are
  ambient, so requests relying on them must not come from another site.
  """

  import Plug.Conn

  alias BabelSync.Auth
  alias BabelSyncWeb.Origin

  @session_key "scope_token"

  def session_key, do: @session_key

  def fetch_scope(conn, _opts) do
    result =
      case bearer(conn) do
        nil -> if foreign?(conn), do: :error, else: Auth.scope_from_session(session_token(conn))
        token -> Auth.scope_from_token(token)
      end

    case result do
      {:ok, scope} -> assign(conn, :current_scope, scope)
      :error -> assign(conn, :current_scope, nil)
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
