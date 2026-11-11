defmodule BabelSync.Auth.LoginLink do
  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "login_links" do
    field :email, :string
    field :token_hash, :binary
    field :expires_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end
end
