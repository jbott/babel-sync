defmodule BabelSync.Accounts do
  @moduledoc """
  Users. In single-user mode there is exactly one, created on first use.
  """

  alias BabelSync.Accounts.User
  alias BabelSync.Repo

  @owner_name "Owner"

  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs) do
    %User{} |> User.changeset(attrs) |> Repo.insert()
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
        {:ok, user} = create_user(%{name: @owner_name})
        user
    end
  end
end
