defmodule BabelSync.Repo.SQLite.Migrations.IndexVersionsByAge do
  use Ecto.Migration

  def change do
    create index(:doc_versions, [:inserted_at])
    create index(:blob_versions, [:inserted_at])
  end
end
