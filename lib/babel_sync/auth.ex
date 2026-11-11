defmodule BabelSync.Auth do
  @moduledoc """
  Turns a credential into a scope.
  """

  alias BabelSync.Accounts
  alias BabelSync.Accounts.Scope

  @socket_salt "socket"
  @socket_max_age 86_400

  @type method :: :none | :passkey | :oidc

  @spec method() :: method()
  def method, do: Application.fetch_env!(:babel_sync, :auth)

  @spec anonymous_scope() :: Scope.t() | nil
  def anonymous_scope do
    if BabelSync.mode() == :single and method() == :none do
      Scope.for_user(Accounts.single_user!())
    end
  end

  @spec socket_token(Scope.t()) :: String.t()
  def socket_token(%Scope{user: user, read_only: read_only}) do
    Phoenix.Token.sign(BabelSyncWeb.Endpoint, @socket_salt, {user.id, read_only})
  end

  @spec scope_from_token(String.t() | nil) :: {:ok, Scope.t()} | :error
  def scope_from_token(nil) do
    case anonymous_scope() do
      %Scope{} = scope -> {:ok, scope}
      nil -> :error
    end
  end

  def scope_from_token(token) when is_binary(token) do
    with {:ok, {user_id, read_only}} <-
           Phoenix.Token.verify(BabelSyncWeb.Endpoint, @socket_salt, token,
             max_age: @socket_max_age
           ),
         %Accounts.User{} = user <- Accounts.get_user(user_id) do
      {:ok, Scope.for_user(user, read_only: read_only)}
    else
      _invalid -> :error
    end
  end
end
