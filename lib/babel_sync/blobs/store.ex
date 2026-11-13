defmodule BabelSync.Blobs.Store do
  @moduledoc """
  Where blob bytes live: a directory in local storage mode, an S3 bucket
  in remote storage mode. Objects are written in numbered parts so a large
  upload can resume, and read back as a stream, optionally of a byte range.
  """

  @type key :: String.t()
  @type ref :: String.t()
  @type tag :: String.t()
  @type range :: {first :: non_neg_integer(), last :: non_neg_integer()} | nil

  @callback start_upload(key()) :: {:ok, ref()} | {:error, term()}
  @callback put_part(key(), ref(), pos_integer(), binary()) :: {:ok, tag()} | {:error, term()}
  @callback finish_upload(key(), ref(), [{pos_integer(), tag()}]) :: :ok | {:error, term()}
  @callback abort_upload(key(), ref()) :: :ok
  @callback stream(key(), range()) :: Enumerable.t()
  @callback delete(key()) :: :ok
  @callback reachable?() :: boolean()

  @spec impl() :: module()
  def impl do
    case BabelSync.storage() do
      :local -> BabelSync.Blobs.Store.Disk
      :remote -> BabelSync.Blobs.Store.S3
    end
  end
end
