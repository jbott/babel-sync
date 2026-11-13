defmodule BabelSync.Repo.Migrations.AddNoteIndex do
  use Ecto.Migration

  def change do
    create table(:note_index, primary_key: false) do
      add :entry_id, references(:entries, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :content_hash, :string, null: false
      add :data, :binary, null: false
      timestamps(type: :utc_datetime_usec, inserted_at: false)
    end
  end
end
