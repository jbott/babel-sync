defmodule BabelSync.Repo.Migrations.AddSourcesFolderToVaults do
  use Ecto.Migration

  def change do
    alter table(:vaults) do
      add :sources_folder, :string
    end
  end
end
