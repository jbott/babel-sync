defmodule BabelSync.BackupTest do
  use BabelSync.DataCase, async: false

  import BabelSync.Fixtures
  import ExUnit.CaptureIO

  alias BabelSync.{Backup, Blobs}

  @tag :tmp_dir
  test "a snapshot of the database and the attachment files are written", %{tmp_dir: dir} do
    vault = vault(user(), %{name: "Kept"})
    {:ok, blob} = Blobs.put(vault.id, "attachment bytes")

    assert backup(dir) =~ ~r/[1-9]\d* new attachment files/

    [snapshot] = Path.wildcard(Path.join(dir, "babel_sync-*.db"))
    {:ok, copy} = Exqlite.Sqlite3.open(snapshot)
    {:ok, statement} = Exqlite.Sqlite3.prepare(copy, "SELECT count(*) FROM vaults")
    assert {:row, [_count]} = Exqlite.Sqlite3.step(copy, statement)

    assert File.read!(Path.join([dir, "blobs", "vaults", vault.id, blob.hash])) ==
             "attachment bytes"

    assert backup(dir) =~ "0 new attachment files"
  end

  defp backup(dir) do
    capture_io(fn -> Backup.run(dir) end)
  end
end
