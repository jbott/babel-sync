defmodule BabelSync.Sync.Update do
  use Ecto.Schema

  @foreign_key_type :binary_id

  schema "doc_updates" do
    field :entry_id, :binary_id
    field :data, :binary
    field :inserted_at, :utc_datetime_usec
  end
end
