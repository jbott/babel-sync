defmodule BabelSync.Blobs.Blob do
  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "blobs" do
    field :vault_id, :binary_id
    field :hash, :string
    field :size, :integer
    field :inserted_at, :utc_datetime_usec
  end
end
