defmodule BabelSyncWeb.EntryJSON do
  alias BabelSync.Vaults.Entry

  @spec entry(Entry.t()) :: map()
  def entry(%Entry{} = entry) do
    %{
      id: entry.id,
      path: entry.path,
      kind: entry.kind,
      blob_hash: entry.blob_hash,
      content_hash: entry.content_hash,
      size: entry.size,
      seq: entry.seq,
      deleted: not is_nil(entry.deleted_at),
      updated_at: entry.updated_at
    }
  end
end
