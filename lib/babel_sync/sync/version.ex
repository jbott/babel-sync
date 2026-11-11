defmodule BabelSync.Sync.Version do
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "doc_versions" do
    field :entry_id, :binary_id
    field :content, :string
    field :content_hash, :string
    field :author_id, :binary_id
    field :inserted_at, :utc_datetime_usec
  end
end
