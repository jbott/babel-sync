defmodule BabelSync.Repo.Migrations.AddHistoryAndTrash do
  use Ecto.Migration

  def change do
    create table(:blob_versions) do
      add :entry_id, references(:entries, type: :binary_id, on_delete: :delete_all), null: false
      add :blob_hash, :string, null: false
      add :size, :bigint, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:blob_versions, [:entry_id, :id])
    create index(:blob_versions, [:blob_hash])
    create index(:entries, [:vault_id, :blob_hash])

    alter table(:vaults) do
      add :purged_seq, :bigint, null: false, default: 0
    end
  end
end
