defmodule BabelSync.Blobs.Part do
  @moduledoc """
  One received part of an attachment upload in progress.
  """

  use BabelSync.Schema

  @type t :: %__MODULE__{}

  schema "upload_parts" do
    field :number, :integer
    field :hash, :string
    field :size, :integer
    field :tag, :string
    belongs_to :upload, BabelSync.Blobs.Upload
  end
end
