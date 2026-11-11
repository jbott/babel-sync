defmodule BabelSync.Vaults.Vault do
  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "vaults" do
    field :name, :string
    field :seq, :integer, default: 0
    has_many :members, BabelSync.Vaults.Member
    timestamps()
  end

  def changeset(vault, attrs) do
    vault
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 200)
  end
end
