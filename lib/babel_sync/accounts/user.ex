defmodule BabelSync.Accounts.User do
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
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+$/)
    |> unique_constraint(:email)
  end
end
