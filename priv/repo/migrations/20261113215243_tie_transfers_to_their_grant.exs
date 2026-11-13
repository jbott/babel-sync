defmodule BabelSync.Repo.Migrations.TieTransfersToTheirGrant do
  use Ecto.Migration

  def change do
    alter table(:file_transfers) do
      add :grant_id, :binary_id
    end
  end
end
