defmodule BabelSync.Vaults.BlobVersion do
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "blob_versions" do
    field :entry_id, :binary_id
    field :blob_hash, :string
    field :size, :integer
    field :inserted_at, :utc_datetime_usec
  end
end
