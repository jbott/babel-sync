defmodule BabelSync.OAuth.Grant do
  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "oauth_grants" do
    field :read_only, :boolean, default: false
    field :access_hash, :binary
    field :access_expires_at, :utc_datetime_usec
    field :refresh_hash, :binary
    field :previous_refresh_hash, :binary
    field :rotated_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    belongs_to :client, BabelSync.OAuth.Client
    belongs_to :user, BabelSync.Accounts.User
    timestamps()
  end
end
