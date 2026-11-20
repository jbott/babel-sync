defmodule BabelSync.Repo.Migrations.AddConnectorSessions do
  use Ecto.Migration

  def change do
    create table(:connector_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vault_id, references(:vaults, type: :binary_id, on_delete: :delete_all), null: false
      add :connection_id, :binary_id, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :sealed, :binary
      add :revision, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:connector_sessions, [:vault_id, :connection_id])
  end
end
