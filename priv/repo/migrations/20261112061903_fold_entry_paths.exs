defmodule BabelSync.Repo.Migrations.FoldEntryPaths do
  use Ecto.Migration

  import Ecto.Query

  def up do
    alter table(:entries) do
      add :folded, :text
    end

    flush()

    from(e in "entries", select: {e.id, e.path})
    |> repo().all()
    |> Enum.each(fn {id, path} ->
      repo().update_all(from(e in "entries", where: e.id == ^id),
        set: [folded: BabelSync.Vaults.Path.fold(path)]
      )
    end)

    create index(:entries, [:vault_id, :folded], where: "deleted_at IS NULL")
  end

  def down do
    drop index(:entries, [:vault_id, :folded])

    alter table(:entries) do
      remove :folded
    end
  end
end
