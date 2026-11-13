defmodule BabelSync.Vaults.Invitation do
  @moduledoc """
  A place in a vault kept for an address that has no account yet. It
  becomes a membership the first time that address signs in.
  """

  use BabelSync.Schema

  alias BabelSync.Accounts.User

  @type t :: %__MODULE__{}

  schema "vault_invitations" do
    field :email, :string
    field :role, Ecto.Enum, values: [:owner, :editor, :viewer]
    belongs_to :vault, BabelSync.Vaults.Vault
    timestamps()
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email, :role])
    |> validate_required([:email, :role])
    |> update_change(:email, &User.normalize_email/1)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+$/)
    |> validate_length(:email, max: 254)
    |> unique_constraint([:vault_id, :email])
  end
end
