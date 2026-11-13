defmodule BabelSync.Accounts.User do
  @moduledoc """
  A person who can sign in and belong to vaults.
  """

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :name, :string
    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name])
    |> update_change(:email, &normalize_email/1)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+$/)
    |> validate_length(:name, max: 100)
    |> unique_constraint(:email)
  end

  @spec normalize_email(String.t()) :: String.t()
  def normalize_email(email), do: email |> String.trim() |> String.downcase()
end
