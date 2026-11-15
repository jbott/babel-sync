defmodule BabelSync.Sources.Run do
  @moduledoc """
  One run of a source: what set it off, which server took it, how it
  ended, what it logged and how many notes it made, changed and found
  already right.
  """

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "source_runs" do
    field :trigger, :string
    field :status, Ecto.Enum, values: [:queued, :running, :done, :failed]
    field :claimed_by, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :error, :string
    field :log, :string, default: ""
    field :created, :integer, default: 0
    field :changed, :integer, default: 0
    field :unchanged, :integer, default: 0
    belongs_to :source, BabelSync.Sources.Source
    timestamps(updated_at: false)
  end
end
