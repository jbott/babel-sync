defmodule BabelSync.Vaults.TextFiles do
  @moduledoc """
  Turns attachments that are really text into notes.

  Which files are notes is decided by extension, and the list grows:
  Obsidian's `.base` and `.canvas` files were attachments before they
  were recognised as text. An attachment whose path now names a note,
  and whose bytes are text, becomes a note with the same identity, so
  devices follow the change instead of seeing a deletion and a new
  file. Its bytes stay in the attachment history.
  """

  import Ecto.Query

  alias BabelSync.{Blobs, Repo, Sync, Vaults}
  alias BabelSync.Vaults.Entry

  @largest 2 * 1024 * 1024

  @spec promote() :: non_neg_integer()
  def promote do
    candidates =
      from e in Entry,
        where: e.kind == :blob and is_nil(e.deleted_at) and not is_nil(e.blob_hash),
        where: e.size <= @largest

    candidates
    |> Repo.all()
    |> Enum.filter(&(Vaults.Path.kind_for(&1.path) == :doc))
    |> Enum.count(&promoted?/1)
  end

  defp promoted?(%Entry{} = entry) do
    with %Blobs.Blob{} = blob <- Blobs.get(entry.vault_id, entry.blob_hash),
         {:ok, text} <- text(Blobs.read(blob)),
         {:ok, note} <- Vaults.update_entry(entry, %{kind: :doc, blob_hash: nil}) do
      :ok = Sync.replace_text(note.id, text)
      :ok = Sync.flush(note.id)
      true
    else
      _left_alone -> false
    end
  end

  defp text(bytes) do
    if String.valid?(bytes) and not String.contains?(bytes, <<0>>),
      do: {:ok, bytes},
      else: :binary
  end
end
