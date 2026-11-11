defmodule BabelSync.Repo.Migrations.TrackOauthClientApproval do
  use Ecto.Migration

  def change do
    alter table(:oauth_clients) do
      add :approved_at, :utc_datetime_usec
    end

    execute(
      "UPDATE oauth_clients SET approved_at = inserted_at WHERE id IN (SELECT client_id FROM oauth_grants)",
      ""
    )

    create index(:oauth_clients, [:approved_at, :inserted_at])
  end
end
