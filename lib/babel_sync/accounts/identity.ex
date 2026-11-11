defmodule BabelSync.Accounts.Identity do
  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "identities" do
    field :issuer, :string
    field :subject, :string
    belongs_to :user, BabelSync.Accounts.User
    timestamps()
  end
end
