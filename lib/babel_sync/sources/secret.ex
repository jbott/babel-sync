defmodule BabelSync.Sources.Secret do
  @moduledoc """
  A secret one source may send to one host, kept encrypted.
  """

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "source_secrets" do
    field :name, :string
    field :sealed, :binary
    belongs_to :source, BabelSync.Sources.Source
    timestamps()
  end
end
