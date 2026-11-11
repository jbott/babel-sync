defmodule BabelSync.Repo.Migrations.LetVaultsOpenConfigToAgents do
  use Ecto.Migration

  def change do
    alter table(:vaults) do
      add :agents_see_config, :boolean, null: false, default: false
    end
  end
end
