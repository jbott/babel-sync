defmodule BabelSync.Repo.Migrations.RecordTheAppBehindAVersion do
  use Ecto.Migration

  def change do
    alter table(:doc_versions) do
      add :author_app, :string
    end
  end
end
