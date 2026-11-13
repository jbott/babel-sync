defmodule BabelSyncWeb.SessionController do
  use BabelSyncWeb, :controller

  alias BabelSync.Auth
  alias BabelSync.Auth.{MagicLink, OIDC}
  alias BabelSyncWeb.Plugs.Scope

  @oidc_flow "oidc_flow"
  @return_to "return_to"

  plug :limit when action in [:complete, :link, :oidc_callback]

  def return_to_key, do: @return_to

  defp limit(conn, _opts) do
    case BabelSync.RateLimit.allow(:sign_in, BabelSyncWeb.ClientAddress.of(conn)) do
      :ok ->
        conn

      {:error, _retry_after} ->
        conn
        |> refuse("Too many attempts from this address. Try again in a minute.")
        |> halt()
    end
  end

  def complete(conn, %{"token" => token}) do
    case Auth.user_from_handoff(token) do
      {:ok, user} -> sign_in(conn, user)
      :error -> refuse(conn, "That sign-in attempt expired. Try again.")
    end
  end

  def link(conn, %{"token" => token}) do
    with true <- Auth.enabled?(:magic_link),
         {:ok, user} <- MagicLink.redeem(token) do
      sign_in(conn, user)
    else
      _invalid -> refuse(conn, "That link has expired or was already used.")
    end
  end

  def oidc(conn, _params) do
    with true <- Auth.enabled?(:oidc),
         {:ok, url, flow} <- OIDC.begin(callback_url()) do
      conn |> put_session(@oidc_flow, flow) |> redirect(external: url)
    else
      _unavailable -> refuse(conn, "Single sign-on is not available right now.")
    end
  end

  def oidc_callback(conn, %{"code" => code, "state" => state}) do
    flow = get_session(conn, @oidc_flow)
    conn = delete_session(conn, @oidc_flow)

    with true <- Auth.enabled?(:oidc),
         %{state: ^state} <- flow,
         {:ok, user} <- OIDC.finish(code, callback_url(), flow) do
      sign_in(conn, user)
    else
      {:error, :not_permitted} -> refuse(conn, "That account is not allowed to sign in here.")
      _invalid -> refuse(conn, "Single sign-on did not complete. Try again.")
    end
  end

  def oidc_callback(conn, _params) do
    conn |> delete_session(@oidc_flow) |> refuse("Single sign-on was cancelled.")
  end

  def delete(conn, _params) do
    conn |> Scope.sign_out() |> redirect(to: ~p"/login")
  end

  defp sign_in(conn, user) do
    destination = get_session(conn, @return_to) || ~p"/"

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> Scope.sign_in(user)
    |> redirect(to: destination)
  end

  defp refuse(conn, message) do
    conn |> put_flash(:error, message) |> redirect(to: ~p"/login")
  end

  defp callback_url, do: url(~p"/login/oidc/callback")
end
