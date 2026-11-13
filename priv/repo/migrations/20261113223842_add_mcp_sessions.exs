defmodule BabelSync.Repo.SQLite.Migrations.AddMcpSessions do
  use Ecto.Migration

  def change do
    create table(:mcp_sessions, primary_key: false) do
      add :id, :string, primary_key: true
      add :state, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create index(:mcp_sessions, [:expires_at])
  end
end
