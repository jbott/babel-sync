defmodule BabelSync.Accounts.Identity do
  @moduledoc """
  A user's account at an OpenID Connect provider, by issuer and subject, so
  signing in there finds the same user again.
  """

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "identities" do
    field :issuer, :string
    field :subject, :string
    belongs_to :user, BabelSync.Accounts.User
    timestamps()
  end
end
