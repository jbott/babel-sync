defmodule BabelSync.Repo.SQLite.Migrations.AddClusterNodes do
  use Ecto.Migration

  def change do
    create table(:cluster_nodes, primary_key: false) do
      add :name, :string, primary_key: true
      add :seen_at, :utc_datetime_usec, null: false
    end
  end
end
