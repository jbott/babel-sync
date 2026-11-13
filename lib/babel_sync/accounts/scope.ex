defmodule BabelSync.Accounts.Scope do
  @moduledoc """
  Who is acting and how far their credential reaches. A browser session
  reaches everything its user can; a token issued to a device or an agent
  may be limited to reading, or to some of the user's vaults.

  A scope also names the credential it came from, a browser session or
  a grant, so that what was opened with it can be closed when it ends.
  """

  alias BabelSync.Accounts.User
  alias BabelSync.Vaults

  @type t :: %__MODULE__{
          user: User.t(),
          read_only: boolean(),
          session_id: Ecto.UUID.t() | nil,
          grant_id: Ecto.UUID.t() | nil,
          vault_ids: [Ecto.UUID.t()] | nil
        }

  defstruct [:user, :session_id, :grant_id, :vault_ids, read_only: false]

  @spec for_user(User.t(), keyword()) :: t()
  def for_user(%User{} = user, opts \\ []) do
    %__MODULE__{
      user: user,
      read_only: Keyword.get(opts, :read_only, false),
      session_id: Keyword.get(opts, :session_id),
      grant_id: Keyword.get(opts, :grant_id),
      vault_ids: Keyword.get(opts, :vault_ids)
    }
  end

  @spec vaults(t()) :: [Vaults.Vault.t()]
  def vaults(%__MODULE__{user: user} = scope) do
    Enum.filter(Vaults.list_vaults(user), &reaches?(scope, &1.id))
  end

  @spec reaches?(t(), Ecto.UUID.t()) :: boolean()
  def reaches?(%__MODULE__{vault_ids: nil}, _vault_id), do: true
  def reaches?(%__MODULE__{vault_ids: allowed}, vault_id), do: vault_id in allowed

  @spec socket_topic(t()) :: String.t()
  def socket_topic(%__MODULE__{grant_id: id}) when is_binary(id), do: grant_topic(id)
  def socket_topic(%__MODULE__{session_id: id}) when is_binary(id), do: session_topic(id)
  def socket_topic(%__MODULE__{user: user}), do: user_topic(user.id)

  @spec grant_topic(Ecto.UUID.t()) :: String.t()
  def grant_topic(id), do: "user_socket:grant:" <> id

  @spec session_topic(Ecto.UUID.t()) :: String.t()
  def session_topic(id), do: "user_socket:session:" <> id

  @spec user_topic(Ecto.UUID.t()) :: String.t()
  def user_topic(id), do: "user_socket:user:" <> id

  @spec authorize(t(), Ecto.UUID.t(), Vaults.access()) :: :ok | {:error, :forbidden}
  def authorize(%__MODULE__{read_only: true}, _vault_id, access) when access != :read do
    {:error, :forbidden}
  end

  def authorize(%__MODULE__{user: user} = scope, vault_id, access) do
    if reaches?(scope, vault_id),
      do: Vaults.authorize(user, vault_id, access),
      else: {:error, :forbidden}
  end
end
