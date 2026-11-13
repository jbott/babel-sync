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

  @tag :tmp_dir
  test "a backup restores into an empty data directory, and never over a database",
       %{tmp_dir: dir} do
    backups = Path.join(dir, "backups")
    restored = Path.join(dir, "data")
    File.mkdir_p!(Path.join([backups, "blobs", "vaults", "restore-test"]))
    File.write!(Path.join([backups, "blobs", "vaults", "restore-test", "hash"]), "bytes")
    File.write!(Path.join(backups, "babel_sync-20200101-000000.db"), "older")
    snapshot = Path.join(backups, "babel_sync-20200102-000000.db")
    {:ok, source} = Exqlite.Sqlite3.open(snapshot)
    :ok = Exqlite.Sqlite3.execute(source, "CREATE TABLE notes (title TEXT)")
    :ok = Exqlite.Sqlite3.execute(source, "INSERT INTO notes VALUES ('kept')")
    :ok = Exqlite.Sqlite3.close(source)

    assert capture_io(fn -> Backup.restore(backups, restored) end) =~ "restored #{snapshot}"

    {:ok, copy} = Exqlite.Sqlite3.open(Path.join(restored, "babel_sync.db"))
    {:ok, statement} = Exqlite.Sqlite3.prepare(copy, "SELECT title FROM notes")
    assert {:row, ["kept"]} = Exqlite.Sqlite3.step(copy, statement)

    assert File.read!(Path.join([restored, "blobs", "vaults", "restore-test", "hash"])) ==
             "bytes"

    assert_raise RuntimeError, ~r/already exists/, fn -> Backup.restore(backups, restored) end
    assert_raise RuntimeError, ~r/no babel_sync/, fn -> Backup.restore(restored, dir) end
  end

  @tag :tmp_dir
  test "only as many snapshots are kept as asked for", %{tmp_dir: dir} do
    for stamp <- ["20200101-000000", "20200102-000000", "20200103-000000"] do
      File.write!(Path.join(dir, "babel_sync-#{stamp}.db"), "old")
    end

    assert capture_io(fn -> Backup.run(dir, keep: 2) end) =~ "removed 2 old snapshots"

    assert [_newest, older] =
             dir |> Path.join("babel_sync-*.db") |> Path.wildcard() |> Enum.sort(:desc)

    assert Path.basename(older) == "babel_sync-20200103-000000.db"
  end

  defp backup(dir), do: capture_io(fn -> Backup.run(dir) end)
end
