defmodule BabelSync.Sources.RunNote do
  @moduledoc """
  A note one run of a source made or edited. It lasts as long as the run
  is kept and the note is in the vault or its trash.
  """

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "source_run_notes" do
    field :outcome, Ecto.Enum, values: [:created, :changed]
    belongs_to :run, BabelSync.Sources.Run
    belongs_to :entry, BabelSync.Vaults.Entry
  end
end
