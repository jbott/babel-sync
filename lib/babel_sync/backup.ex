defmodule BabelSync.Backup do
  @moduledoc """
  A consistent copy of a local-mode server while it runs, and the way
  back from one.

  Copying `babel_sync.db` directly can catch it half written, because
  SQLite keeps recent writes in a separate log. `VACUUM INTO` writes a
  complete snapshot instead. Attachments are named by their content and
  never change, so they are copied into a `blobs` folder beside it,
  skipping any already there.

      babel_sync eval 'BabelSync.Backup.run("/backups/babelsync")'
      babel_sync eval 'BabelSync.Backup.run("/backups/babelsync", keep: 14)'

  Every run adds a snapshot; `keep` removes all but the newest that
  many. Attachments are never removed from a backup, since any kept
  snapshot may still refer to them.

  Restoring puts the newest snapshot, or the one named, and the
  attachments into the data directory of a server that is stopped and
  has no database there yet. It never writes over a database.

      babel_sync eval 'BabelSync.Backup.restore("/backups/babelsync")'
  """

  @database "babel_sync.db"

  @spec run(Path.t(), keep: pos_integer()) :: :ok
  def run(destination, opts \\ []) do
    {:ok, _started} = Application.ensure_all_started(:babel_sync)

    if BabelSync.Repo.adapter() != :sqlite do
      raise "BabelSync.Backup covers local mode; back up PostgreSQL with pg_dump and the bucket with its own tools"
    end

    File.mkdir_p!(destination)
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    snapshot = Path.join(destination, "babel_sync-#{stamp}.db")
    File.rm(snapshot)
    snapshot!(snapshot)

    copied = copy_new(Path.join(BabelSync.data_dir(), "blobs"), Path.join(destination, "blobs"))
    removed = if opts[:keep], do: forget_old(destination, opts[:keep]), else: 0

    IO.puts(
      "wrote #{snapshot} and #{copied} new attachment files, removed #{removed} old snapshots"
    )
  end

  @spec restore(Path.t(), Path.t()) :: :ok
  def restore(source, data_dir \\ data_dir()) do
    snapshot = if File.dir?(source), do: newest!(source), else: source
    database = Path.join(data_dir, @database)

    if File.exists?(database) do
      raise "#{database} already exists; stop the server and move it away before restoring"
    end

    File.mkdir_p!(data_dir)
    File.cp!(snapshot, database <> ".partial")
    File.rename!(database <> ".partial", database)

    copied =
      copy_new(Path.join(Path.dirname(snapshot), "blobs"), Path.join(data_dir, "blobs"))

    IO.puts("restored #{snapshot} to #{database} with #{copied} attachment files")
  end

  defp data_dir do
    _loaded = Application.load(:babel_sync)
    BabelSync.data_dir()
  end

  defp snapshots(folder) do
    folder |> Path.join("babel_sync-*.db") |> Path.wildcard() |> Enum.sort(:desc)
  end

  defp newest!(folder) do
    case snapshots(folder) do
      [newest | _older] -> newest
      [] -> raise "no babel_sync-*.db snapshot in #{folder}"
    end
  end

  defp forget_old(folder, keep) when is_integer(keep) and keep > 0 do
    old = folder |> snapshots() |> Enum.drop(keep)
    Enum.each(old, &File.rm!/1)
    length(old)
  end

  defp snapshot!(target) do
    database = Application.fetch_env!(:babel_sync, BabelSync.Repo.SQLite)[:database]
    {:ok, connection} = Exqlite.Sqlite3.open(database)

    try do
      :ok = Exqlite.Sqlite3.execute(connection, "PRAGMA busy_timeout = 10000")

      :ok =
        Exqlite.Sqlite3.execute(connection, "VACUUM INTO '#{String.replace(target, "'", "''")}'")
    after
      Exqlite.Sqlite3.close(connection)
    end
  end

  defp copy_new(from, to) do
    from
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.count(fn source ->
      target = Path.join(to, Path.relative_to(source, from))

      if File.exists?(target) do
        false
      else
        File.mkdir_p!(Path.dirname(target))
        File.cp!(source, target <> ".partial")
        File.rename!(target <> ".partial", target)
        true
      end
    end)
  end
end
