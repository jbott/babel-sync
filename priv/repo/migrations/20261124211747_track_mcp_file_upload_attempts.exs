defmodule BabelSync.Repo.Migrations.TrackMcpFileUploadAttempts do
  use Ecto.Migration

  def change do
    alter table(:mcp_file_uploads) do
      add :receiving_until, :utc_datetime_usec
      add :consumed_at, :utc_datetime_usec
    end
  end
end
