defmodule BabelSync.Sync.Settled do
  @moduledoc """
  The last stored update that a note's saved text accounts for. A note
  with a later update has edits its saved text may lack.
  """

  use Ecto.Schema

  @primary_key {:entry_id, :binary_id, autogenerate: false}

  schema "doc_settled" do
    field :update_id, :integer
  end
end
