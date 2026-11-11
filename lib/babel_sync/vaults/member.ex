defmodule BabelSync.Vaults.Member do
  use BabelSync.Schema

  @type t :: %__MODULE__{}
  @type role :: :owner | :editor | :viewer

  schema "vault_members" do
    field :role, Ecto.Enum, values: [:owner, :editor, :viewer]
    belongs_to :vault, BabelSync.Vaults.Vault
    belongs_to :user, BabelSync.Accounts.User
    timestamps()
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> unique_constraint([:vault_id, :user_id])
  end
end
