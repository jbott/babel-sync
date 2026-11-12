defmodule BabelSync.Repo.Migrations.AddFileTransfers do
  use Ecto.Migration

  def change do
    create table(:file_transfers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :binary, null: false
      add :direction, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :vault_id, references(:vaults, type: :binary_id, on_delete: :delete_all), null: false
      add :entry_id, references(:entries, type: :binary_id, on_delete: :delete_all)
      add :path, :text
      add :size, :bigint
      add :overwrite, :boolean, null: false, default: false
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:file_transfers, [:token_hash])
    create index(:file_transfers, [:expires_at])
  end
end
