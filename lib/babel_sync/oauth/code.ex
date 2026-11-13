defmodule BabelSync.OAuth.Code do
  @moduledoc """
  A one-time OAuth authorization code, kept as a hash with the PKCE
  challenge it must be redeemed with.
  """

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "oauth_codes" do
    field :code_hash, :binary
    field :redirect_uri, :string
    field :challenge, :string
    field :read_only, :boolean, default: false
    field :vault_ids, {:array, :string}
    field :expires_at, :utc_datetime_usec
    belongs_to :client, BabelSync.OAuth.Client
    belongs_to :user, BabelSync.Accounts.User
    timestamps(updated_at: false)
  end
end
