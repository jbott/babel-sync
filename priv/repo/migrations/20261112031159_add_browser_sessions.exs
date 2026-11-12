defmodule BabelSync.Repo.Migrations.AddBrowserSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :agent, :string, null: false, default: ""
      add :last_seen_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:sessions, [:user_id])

    execute(
      "UPDATE oauth_clients SET name = substr(name, 11, length(name) - 11) WHERE name LIKE 'Obsidian (%)'",
      ""
    )
  end
end
