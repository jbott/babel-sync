defmodule BabelSync.Sources.Item do
  @moduledoc """
  Which note stands for one thing a source brings in, and the properties
  the source last set on it. The note is known by its entry, so it may
  be renamed or moved; one whose note was deleted is marked gone, and is
  not made again.
  """

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "source_items" do
    field :key, :string
    field :written, :string, default: "{}"
    field :gone, :boolean, default: false
    belongs_to :source, BabelSync.Sources.Source
    belongs_to :entry, BabelSync.Vaults.Entry
    timestamps()
  end
end
