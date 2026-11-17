defmodule BabelSync.Repo.Migrations.AddSourceRunNotes do
  use Ecto.Migration

  def change do
    create table(:source_run_notes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:source_runs, type: :binary_id, on_delete: :delete_all), null: false
      add :entry_id, references(:entries, type: :binary_id, on_delete: :delete_all), null: false
      add :outcome, :string, null: false
    end

    create unique_index(:source_run_notes, [:run_id, :entry_id])
    create index(:source_run_notes, [:entry_id])
  end
end
