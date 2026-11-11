defmodule BabelSync.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string
      add :name, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])

    create table(:vaults, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :seq, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create table(:vault_members, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vault_id, references(:vaults, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:vault_members, [:vault_id, :user_id])
    create index(:vault_members, [:user_id])

    create table(:entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vault_id, references(:vaults, type: :binary_id, on_delete: :delete_all), null: false
      add :path, :text, null: false
      add :kind, :string, null: false
      add :blob_hash, :string
      add :content_hash, :string
      add :size, :bigint, null: false, default: 0
      add :seq, :bigint, null: false
      add :deleted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:entries, [:vault_id, :path],
             where: "deleted_at IS NULL",
             name: :entries_live_path_index
           )

    create index(:entries, [:vault_id, :seq])

    create table(:doc_updates) do
      add :entry_id, references(:entries, type: :binary_id, on_delete: :delete_all), null: false
      add :data, :binary, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:doc_updates, [:entry_id, :id])

    create table(:doc_states, primary_key: false) do
      add :entry_id, references(:entries, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :data, :binary, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:doc_versions) do
      add :entry_id, references(:entries, type: :binary_id, on_delete: :delete_all), null: false
      add :content, :text, null: false
      add :content_hash, :string, null: false
      add :author_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:doc_versions, [:entry_id, :id])
  end
end
