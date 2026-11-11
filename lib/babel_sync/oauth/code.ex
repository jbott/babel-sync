defmodule BabelSync.OAuth.Code do
  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "oauth_codes" do
    field :code_hash, :binary
    field :redirect_uri, :string
    field :challenge, :string
    field :read_only, :boolean, default: false
    field :expires_at, :utc_datetime_usec
    belongs_to :client, BabelSync.OAuth.Client
    belongs_to :user, BabelSync.Accounts.User
    timestamps(updated_at: false)
  end
end
