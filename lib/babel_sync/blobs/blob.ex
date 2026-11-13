defmodule BabelSync.Blobs.Blob do
  @moduledoc """
  Attachment bytes stored for a vault, named by their SHA-256 hash.
  """

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "blobs" do
    field :vault_id, :binary_id
    field :hash, :string
    field :size, :integer
    field :inserted_at, :utc_datetime_usec
  end
end
