defmodule BabelSync.Sources.Source do
  @moduledoc """
  A script an admin approved to run for a vault: the manifest and code as
  they were when approved, which is what runs whatever the note says
  now, and what the script has asked to remember between runs.
  """

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "sources" do
    field :name, :string
    field :manifest, :string
    field :code, :string
    field :approved_hash, :string
    field :approved_at, :utc_datetime_usec
    field :enabled, :boolean, default: true
    field :state, :string, default: "{}"
    field :attention, :string
    field :next_run_at, :utc_datetime_usec
    field :running_until, :utc_datetime_usec
    belongs_to :vault, BabelSync.Vaults.Vault
    belongs_to :entry, BabelSync.Vaults.Entry
    belongs_to :approved_by, BabelSync.Accounts.User
    timestamps()
  end
end
