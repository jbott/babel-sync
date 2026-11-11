defmodule BabelSync.Repo.Migrations.CreateBlobs do
  use Ecto.Migration

  def change do
    create table(:blobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vault_id, references(:vaults, type: :binary_id, on_delete: :delete_all), null: false
      add :hash, :string, null: false
      add :size, :bigint, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:blobs, [:vault_id, :hash])

    create table(:uploads, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vault_id, references(:vaults, type: :binary_id, on_delete: :delete_all), null: false
      add :hash, :string, null: false
      add :size, :bigint, null: false
      add :part_size, :bigint, null: false
      add :store_ref, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:uploads, [:vault_id, :hash])

    create table(:upload_parts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :upload_id, references(:uploads, type: :binary_id, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :hash, :string, null: false
      add :size, :bigint, null: false
      add :tag, :text, null: false
    end

    create unique_index(:upload_parts, [:upload_id, :number])
  end
end
