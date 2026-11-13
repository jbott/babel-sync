defmodule BabelSync.Repo.Migrations.AddVaultInvitations do
  use Ecto.Migration

  def change do
    create table(:vault_invitations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :vault_id, references(:vaults, type: :binary_id, on_delete: :delete_all), null: false
      add :email, :string, null: false
      add :role, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:vault_invitations, [:vault_id, :email])
    create index(:vault_invitations, [:email])
  end
end
