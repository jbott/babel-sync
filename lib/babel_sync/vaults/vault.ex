defmodule BabelSync.Vaults.Vault do
  @moduledoc """
  A synced folder of notes and attachments, with the sequence number of
  its latest change.
  """

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "vaults" do
    field :name, :string
    field :seq, :integer, default: 0
    field :purged_seq, :integer, default: 0
    field :agents_see_config, :boolean, default: false
    field :sources_folder, :string
    has_many :members, BabelSync.Vaults.Member
    timestamps()
  end

  def changeset(vault, attrs) do
    vault
    |> cast(attrs, [:name, :agents_see_config, :sources_folder])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 200)
    |> update_change(:sources_folder, &(&1 && BabelSync.Vaults.Path.normalize(&1)))
    |> validate_change(:sources_folder, &folder/2)
  end

  defp folder(:sources_folder, folder) do
    if BabelSync.Vaults.Path.valid?(folder) and
         not String.starts_with?(String.downcase(folder), ".obsidian"),
       do: [],
       else: [sources_folder: "is not a folder a vault can have"]
  end
end
