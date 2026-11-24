defmodule BabelSync.Repo.Migrations.CreateMcpFileUploads do
  use Ecto.Migration

  def change do
    create table(:mcp_file_uploads, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :state_hash, :binary, null: false
      add :target_hash, :binary
      add :arguments_hash, :binary, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :grant_id, :binary_id
      add :vault_id, references(:vaults, type: :binary_id, on_delete: :delete_all), null: false
      add :size, :bigint, null: false
      add :digest, :binary
      add :blob_id, references(:blobs, type: :binary_id, on_delete: :nilify_all)
      add :expires_at, :utc_datetime_usec, null: false
    end

    create unique_index(:mcp_file_uploads, [:state_hash])
    create unique_index(:mcp_file_uploads, [:target_hash])
    create index(:mcp_file_uploads, [:blob_id])
    create index(:mcp_file_uploads, [:expires_at])

    alter table(:file_transfers) do
      add :snapshot_text, :binary
      add :blob_id, references(:blobs, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:file_transfers, [:blob_id])
  end
end
