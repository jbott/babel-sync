defmodule BabelSync.Transfers.Transfer do
  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "file_transfers" do
    field :token_hash, :binary
    field :direction, Ecto.Enum, values: [:upload, :download]
    field :user_id, :binary_id
    field :vault_id, :binary_id
    field :entry_id, :binary_id
    field :path, :string
    field :size, :integer
    field :overwrite, :boolean, default: false
    field :expires_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end
end
