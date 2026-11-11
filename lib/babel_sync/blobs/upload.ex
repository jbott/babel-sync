defmodule BabelSync.Blobs.Upload do
  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "uploads" do
    field :vault_id, :binary_id
    field :hash, :string
    field :size, :integer
    field :part_size, :integer
    field :store_ref, :string
    has_many :parts, BabelSync.Blobs.Part
    timestamps()
  end
end
