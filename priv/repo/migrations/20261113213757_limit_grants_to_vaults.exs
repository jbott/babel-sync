defmodule BabelSync.Repo.Migrations.LimitGrantsToVaults do
  use Ecto.Migration

  def change do
    alter table(:oauth_codes) do
      add :vault_ids, {:array, :string}
    end

    alter table(:oauth_grants) do
      add :vault_ids, {:array, :string}
    end
  end
end
