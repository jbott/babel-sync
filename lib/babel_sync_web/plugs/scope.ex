defmodule BabelSyncWeb.Plugs.Scope do
  @moduledoc """
  Resolves who is making an HTTP request: a bearer token, the browser
  session, or the owner when single-user sign-in is disabled.
  """

  import Plug.Conn

  alias BabelSync.Auth

  @session_key "scope_token"

  def session_key, do: @session_key

  def fetch_scope(conn, _opts) do
    token = bearer(conn) || session_token(conn)

    case Auth.scope_from_token(token) do
      {:ok, scope} -> assign(conn, :current_scope, scope)
      :error -> assign(conn, :current_scope, nil)
    end
  end

  def require_scope(%{assigns: %{current_scope: nil}} = conn, _opts) do
    conn
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

  defp session_token(%{private: %{plug_session: session}}), do: session[@session_key]
  defp session_token(_conn), do: nil
end
