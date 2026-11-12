defmodule BabelSyncWeb.VaultLive.TreeTest do
  use ExUnit.Case, async: true

  alias BabelSync.Vaults.Entry
  alias BabelSyncWeb.VaultLive.Tree

  defp names(paths) do
    paths
    |> Enum.map(&%Entry{path: &1, kind: :doc})
    |> Tree.build()
    |> Enum.map(& &1.name)
  end

  test "numbers in names sort by value, folders first, case ignored" do
    assert names([
             "Note 10.md",
             "note 2.md",
             "Note 1.md",
             "Folder 10/a.md",
             "Folder 2/a.md",
             "2026-11-12.md",
             "2026-1-3.md",
             "Zebra.md"
           ]) == [
             "Folder 2",
             "Folder 10",
             "2026-1-3.md",
             "2026-11-12.md",
             "Note 1.md",
             "note 2.md",
             "Note 10.md",
             "Zebra.md"
           ]
  end
end
