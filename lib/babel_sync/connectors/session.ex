defmodule BabelSync.Connectors.Session do
  @moduledoc false
  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "connector_sessions" do
    field :connection_id, :binary_id
    field :sealed, :binary, redact: true
    field :revision, :integer, default: 0
    belongs_to :vault, BabelSync.Vaults.Vault
    belongs_to :user, BabelSync.Accounts.User
    timestamps()
  end
end
