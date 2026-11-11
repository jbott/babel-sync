defmodule BabelSync.Accounts.Scope do
  @moduledoc """
  Who is acting and how far their credential reaches. A browser session
  reaches everything its user can; a token issued to a device or an agent
  may be limited to reading.
  """

  alias BabelSync.Accounts.User
  alias BabelSync.Vaults

  @type t :: %__MODULE__{user: User.t(), read_only: boolean()}

  defstruct [:user, read_only: false]

  @spec for_user(User.t(), keyword()) :: t()
  def for_user(%User{} = user, opts \\ []) do
    %__MODULE__{user: user, read_only: Keyword.get(opts, :read_only, false)}
  end

  @spec authorize(t(), Ecto.UUID.t(), Vaults.access()) :: :ok | {:error, :forbidden}
  def authorize(%__MODULE__{read_only: true}, _vault_id, access) when access != :read do
    {:error, :forbidden}
  end

  def authorize(%__MODULE__{user: user}, vault_id, access) do
    Vaults.authorize(user, vault_id, access)
  end
end
