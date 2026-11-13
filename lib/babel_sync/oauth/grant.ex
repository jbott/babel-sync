defmodule BabelSync.OAuth.Grant do
  @moduledoc """
  A user's standing permission for an OAuth client: hashes of its access
  and refresh tokens, when each expires, and when it was last used.
  """

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
