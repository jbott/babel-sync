defmodule BabelSync.Vaults.Entry do
  use BabelSync.Schema

  @type t :: %__MODULE__{}
  @type kind :: :doc | :blob | :folder

  schema "entries" do
    field :path, :string
    field :kind, Ecto.Enum, values: [:doc, :blob, :folder]
    field :blob_hash, :string
    field :content_hash, :string
    field :size, :integer, default: 0
    field :seq, :integer
    field :deleted_at, :utc_datetime_usec
    belongs_to :vault, BabelSync.Vaults.Vault
    timestamps()
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:path, :kind, :blob_hash, :content_hash, :size])
    |> validate_required([:path, :kind])
    |> update_change(:path, &BabelSync.Vaults.Path.normalize/1)
    |> validate_change(:path, fn :path, path ->
      if BabelSync.Vaults.Path.valid?(path), do: [], else: [path: "is not a valid vault path"]
    end)
    |> unique_constraint(:path, name: :entries_live_path_index)
  end
end
