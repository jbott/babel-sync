defmodule BabelSync.MCP.SavedSession do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "mcp_sessions" do
    field :state, :string
    field :expires_at, :utc_datetime_usec
  end
end
