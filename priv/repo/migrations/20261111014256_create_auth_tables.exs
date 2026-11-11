defmodule BabelSync.Repo.Migrations.CreateAuthTables do
  use Ecto.Migration

  def change do
    create table(:identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :issuer, :string, null: false
      add :subject, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:identities, [:issuer, :subject])
    create index(:identities, [:user_id])

    create table(:passkeys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :credential_id, :binary, null: false
      add :public_key, :binary, null: false
      add :sign_count, :bigint, null: false, default: 0
      add :name, :string, null: false
      add :last_used_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:passkeys, [:credential_id])
    create index(:passkeys, [:user_id])

    create table(:login_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :token_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:login_links, [:token_hash])

    create table(:oauth_clients, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :redirect_uris, {:array, :string}, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:oauth_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :client_id, references(:oauth_clients, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :code_hash, :binary, null: false
      add :redirect_uri, :text, null: false
      add :challenge, :string, null: false
      add :read_only, :boolean, null: false, default: false
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:oauth_codes, [:code_hash])

    create table(:oauth_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :client_id, references(:oauth_clients, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :read_only, :boolean, null: false, default: false
      add :access_hash, :binary, null: false
      add :access_expires_at, :utc_datetime_usec, null: false
      add :refresh_hash, :binary, null: false
      add :previous_refresh_hash, :binary
      add :rotated_at, :utc_datetime_usec
      add :last_used_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:oauth_grants, [:access_hash])
    create unique_index(:oauth_grants, [:refresh_hash])
    create index(:oauth_grants, [:previous_refresh_hash])
    create index(:oauth_grants, [:user_id])
  end
end
