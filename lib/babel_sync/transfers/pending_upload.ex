defmodule BabelSync.Transfers.PendingUpload do
  @moduledoc false

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "mcp_file_uploads" do
    field :state_hash, :binary
    field :target_hash, :binary
    field :arguments_hash, :binary
    field :user_id, :binary_id
    field :grant_id, :binary_id
    field :vault_id, :binary_id
    field :size, :integer
    field :digest, :binary
    field :blob_id, :binary_id
    field :receiving_until, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
  end
end
