defmodule BabelSync.Repo.Migrations.AddSources do
  use Ecto.Migration

  def change do
    create table(:sources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vault_id, references(:vaults, type: :binary_id, on_delete: :delete_all), null: false
      add :entry_id, references(:entries, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :manifest, :text, null: false
      add :code, :text, null: false
      add :approved_hash, :string, null: false
      add :approved_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :approved_at, :utc_datetime_usec, null: false
      add :enabled, :boolean, null: false, default: true
      add :state, :text, null: false, default: "{}"
      add :attention, :text
      add :next_run_at, :utc_datetime_usec
      add :running_until, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sources, [:entry_id])
    create index(:sources, [:vault_id])
    create index(:sources, [:next_run_at])

    create table(:source_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :key, :text, null: false
      add :entry_id, references(:entries, type: :binary_id, on_delete: :nilify_all)
      add :written, :text, null: false, default: "{}"
      add :gone, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:source_items, [:source_id, :key])

    create table(:source_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :trigger, :string, null: false
      add :status, :string, null: false
      add :claimed_by, :string
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :error, :text
      add :log, :text, null: false, default: ""
      add :created, :integer, null: false, default: 0
      add :changed, :integer, null: false, default: 0
      add :unchanged, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:source_runs, [:source_id, :inserted_at])
    create index(:source_runs, [:status])

    create table(:source_secrets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_id, references(:sources, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :sealed, :binary, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:source_secrets, [:source_id, :name])
  end
end
