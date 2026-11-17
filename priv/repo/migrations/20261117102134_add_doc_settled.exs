defmodule BabelSync.Repo.Migrations.AddDocSettled do
  use Ecto.Migration

  def up do
    create table(:doc_settled, primary_key: false) do
      add :entry_id, references(:entries, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :update_id, :bigint, null: false
    end

    execute("""
    INSERT INTO doc_settled (entry_id, update_id)
    SELECT u.entry_id, max(u.id)
    FROM doc_updates u
    GROUP BY u.entry_id
    HAVING max(u.inserted_at) <
      (SELECT max(v.inserted_at) FROM doc_versions v WHERE v.entry_id = u.entry_id)
    """)
  end

  def down do
    drop table(:doc_settled)
  end
end
