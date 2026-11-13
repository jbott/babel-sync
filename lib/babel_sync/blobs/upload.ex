defmodule BabelSync.Blobs.Upload do
  @moduledoc """
  An attachment upload in progress: the hash and size it will have, the
  part size, and the storage's own handle for it.
  """

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
