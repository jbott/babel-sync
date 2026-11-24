defmodule BabelSync.Transfers.Transfer do
  @moduledoc """
  An opaque link to upload or download one file over HTTP. Only a hash of
  its token is kept, with who may use it, for what, and until when.
  """

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "file_transfers" do
    field :token_hash, :binary
    field :direction, Ecto.Enum, values: [:upload, :download]
    field :user_id, :binary_id
    field :grant_id, :binary_id
    field :vault_id, :binary_id
    field :entry_id, :binary_id
    field :path, :string
    field :snapshot_text, :binary
    field :blob_id, :binary_id
    field :size, :integer
    field :overwrite, :boolean, default: false
    field :expires_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end
end
