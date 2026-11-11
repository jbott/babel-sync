defmodule BabelSync.Vaults.Vault do
  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "vaults" do
    field :name, :string
    field :seq, :integer, default: 0
    field :purged_seq, :integer, default: 0
    field :agents_see_config, :boolean, default: false
    has_many :members, BabelSync.Vaults.Member
    timestamps()
  end

  def changeset(vault, attrs) do
    vault
    |> cast(attrs, [:name, :agents_see_config])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 200)
  end
end
