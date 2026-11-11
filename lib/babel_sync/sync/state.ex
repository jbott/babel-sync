defmodule BabelSync.Sync.State do
  use Ecto.Schema

  @primary_key {:entry_id, :binary_id, autogenerate: false}

  schema "doc_states" do
    field :data, :binary
    field :updated_at, :utc_datetime_usec
  end
end
