defmodule BabelSync.BackupTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias BabelSync.Backup

  @moduletag :local_storage

  @tag :tmp_dir
  test "a snapshot of the database and the attachment files are written", %{tmp_dir: dir} do
    stored = Path.join([BabelSync.data_dir(), "blobs", "vaults", "backup-test", "hash"])
    File.mkdir_p!(Path.dirname(stored))
    File.write!(stored, "attachment bytes")
    on_exit(fn -> File.rm_rf!(Path.dirname(stored)) end)

    assert backup(dir) =~ ~r/[1-9]\d* new attachment files/

    [snapshot] = Path.wildcard(Path.join(dir, "babel_sync-*.db"))
    {:ok, copy} = Exqlite.Sqlite3.open(snapshot)
    {:ok, statement} = Exqlite.Sqlite3.prepare(copy, "SELECT count(*) FROM vaults")
    assert {:row, [_count]} = Exqlite.Sqlite3.step(copy, statement)

    assert File.read!(Path.join([dir, "blobs", "vaults", "backup-test", "hash"])) ==
             "attachment bytes"

    assert backup(dir) =~ "0 new attachment files"
  end

  defp backup(dir), do: capture_io(fn -> Backup.run(dir) end)
end
