defmodule BabelSync.Accounts do
  @moduledoc """
  Users. In single-user mode there is exactly one, created on first use,
  and every way of signing in leads to it.
  """

  alias BabelSync.Accounts.{Identity, Sessions, User}
  alias BabelSync.Repo
  alias BabelSync.Vaults

  @owner_name "Owner"
  @owner_id "00000000-0000-4000-8000-000000000001"

  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs) do
    %User{} |> User.changeset(attrs) |> Repo.insert()
  end

  @spec update_user(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user(%User{} = user, attrs) do
    user |> User.changeset(Map.take(attrs, ["name", :name])) |> Repo.update()
  end

  @spec change_user(User.t(), map()) :: Ecto.Changeset.t()
  def change_user(%User{} = user, attrs \\ %{}), do: User.changeset(user, attrs)

  @doc """
  Removes a person and everything that is only theirs: their sign-ins,
  the apps they approved, and the vaults nobody else is a member of. A
  vault they alone own but others use is not theirs to take away, so
  the account stays until it has another owner or has been deleted.
  """
  @spec delete_user(User.t()) :: :ok | {:error, {:sole_owner, [String.t()]}}
  def delete_user(%User{} = user) do
    owned = Enum.filter(Vaults.list_vaults(user), &Vaults.sole_owner?(&1, user))
    {alone, shared} = Enum.split_with(owned, &(length(Vaults.list_members(&1)) == 1))

    case shared do
      [] ->
        Enum.each(alone, fn vault -> {:ok, _deleted} = Vaults.delete_vault(vault) end)
        :ok = Sessions.finish_others(user, nil)
        :ok = BabelSync.OAuth.revoke_grants(user)
        Repo.delete!(user)
        :ok

      still_needed ->
        {:error, {:sole_owner, Enum.map(still_needed, & &1.name)}}
    end
  end

  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: User.normalize_email(email))
  end

  @spec get_user(Ecto.UUID.t()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @spec single_user!() :: User.t()
  def single_user! do
    :single = BabelSync.mode()

    case Repo.all(User) do
      [user] ->
        user

      [] ->
        Repo.insert!(%User{id: @owner_id, name: @owner_name},
          on_conflict: :nothing,
          conflict_target: :id
        )

        Repo.get!(User, @owner_id)
    end
  end

  @spec user_for_email(String.t()) :: User.t()
  def user_for_email(email) do
    case BabelSync.mode() do
      :single -> single_user!()
      :multi -> get_user_by_email(email) || create_user!(%{email: email})
    end
  end

  @spec user_for_identity(String.t(), String.t(), %{
          optional(:email) => String.t() | nil,
          optional(:name) => String.t() | nil
        }) :: User.t()
  def user_for_identity(issuer, subject, profile) do
    case Repo.get_by(Identity, issuer: issuer, subject: subject) do
      %Identity{user_id: user_id} ->
        Repo.get!(User, user_id)

      nil ->
        user = owner_of(profile)
        Repo.insert!(%Identity{user_id: user.id, issuer: issuer, subject: subject})
        user
    end
  end

  defp owner_of(profile) do
    email = profile[:email]

    cond do
      BabelSync.mode() == :single -> single_user!()
      is_nil(email) -> create_user!(%{name: profile[:name]})
      user = get_user_by_email(email) -> user
      true -> create_user!(%{email: email, name: profile[:name]})
    end
  end

  defp create_user!(attrs) do
    {:ok, user} = create_user(attrs)
    :ok = Vaults.accept_invitations(user)
    user
  end
end
