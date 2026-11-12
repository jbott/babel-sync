defmodule BabelSync.Auth do
  @moduledoc """
  Turns a credential into a scope, and knows which ways of signing in
  this server offers.
  """

  alias BabelSync.Accounts
  alias BabelSync.Accounts.{Scope, Session, Sessions, User}
  alias BabelSync.OAuth

  @socket_salt "socket"
  @socket_max_age 86_400
  @session_salt "session"
  @session_max_age 30 * 86_400
  @handoff_salt "handoff"
  @handoff_max_age 60

  @type method :: :passkey | :oidc | :magic_link

  @spec methods() :: [method()]
  def methods, do: Application.fetch_env!(:babel_sync, :auth)

  @spec enabled?(method()) :: boolean()
  def enabled?(method), do: method in methods()

  @spec open?() :: boolean()
  def open?, do: BabelSync.mode() == :single and methods() == []

  @spec anonymous_scope() :: Scope.t() | nil
  def anonymous_scope do
    if open?(), do: Scope.for_user(Accounts.single_user!())
  end

  @spec socket_token(Scope.t()) :: String.t()
  def socket_token(%Scope{user: user, read_only: read_only}) do
    Phoenix.Token.sign(BabelSyncWeb.Endpoint, @socket_salt, {user.id, read_only})
  end

  @spec session_token(Session.t()) :: String.t()
  def session_token(%Session{id: id}) do
    Phoenix.Token.sign(BabelSyncWeb.Endpoint, @session_salt, {:session, id})
  end

  @spec session_lifetime() :: pos_integer()
  def session_lifetime, do: @session_max_age

  @spec handoff_token(User.t()) :: String.t()
  def handoff_token(%User{id: id}) do
    Phoenix.Token.sign(BabelSyncWeb.Endpoint, @handoff_salt, id)
  end

  @spec user_from_handoff(String.t()) :: {:ok, User.t()} | :error
  def user_from_handoff(token), do: user_from(token, @handoff_salt, @handoff_max_age)

  @spec scope_from_session(String.t() | nil) :: {:ok, Scope.t()} | :error
  def scope_from_session(nil), do: anonymous()

  def scope_from_session(token) when is_binary(token) do
    with {:ok, {:session, id}} <-
           Phoenix.Token.verify(BabelSyncWeb.Endpoint, @session_salt, token,
             max_age: @session_max_age
           ),
         {:ok, %Session{user: user}} <- Sessions.fetch(id) do
      {:ok, Scope.for_user(user, session_id: id)}
    else
      {:ok, user_id} when is_binary(user_id) -> before_sessions(user_id)
      _invalid -> anonymous()
    end
  end

  @spec scope_from_token(String.t() | nil) :: {:ok, Scope.t()} | :error
  def scope_from_token(nil), do: anonymous()

  def scope_from_token(token) when is_binary(token) do
    if OAuth.access_token?(token),
      do: OAuth.scope_from_access_token(token),
      else: scope_from_socket_token(token)
  end

  defp scope_from_socket_token(token) do
    with {:ok, {user_id, read_only}} <-
           Phoenix.Token.verify(BabelSyncWeb.Endpoint, @socket_salt, token,
             max_age: @socket_max_age
           ),
         %User{} = user <- Accounts.get_user(user_id) do
      {:ok, Scope.for_user(user, read_only: read_only)}
    else
      _invalid -> :error
    end
  end

  defp user_from(token, salt, max_age) do
    with {:ok, user_id} <-
           Phoenix.Token.verify(BabelSyncWeb.Endpoint, salt, token, max_age: max_age),
         %User{} = user <- Accounts.get_user(user_id) do
      {:ok, user}
    else
      _invalid -> :error
    end
  end

  defp before_sessions(user_id) do
    case Accounts.get_user(user_id) do
      %User{} = user -> {:ok, Scope.for_user(user)}
      nil -> anonymous()
    end
  end

  defp anonymous do
    case anonymous_scope() do
      %Scope{} = scope -> {:ok, scope}
      nil -> :error
    end
  end
end
