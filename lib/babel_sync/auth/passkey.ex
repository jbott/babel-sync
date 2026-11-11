defmodule BabelSync.Auth.Passkey do
  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "passkeys" do
    field :credential_id, :binary
    field :public_key, :binary
    field :sign_count, :integer, default: 0
    field :name, :string
    field :last_used_at, :utc_datetime_usec
    belongs_to :user, BabelSync.Accounts.User
    timestamps()
  end
end
