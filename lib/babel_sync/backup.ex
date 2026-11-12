defmodule BabelSync.Backup do
  @moduledoc """
  A consistent copy of a local-mode server while it runs.

  Copying `babel_sync.db` directly can catch it half written, because
  SQLite keeps recent writes in a separate log. `VACUUM INTO` writes a
  complete snapshot instead. Attachments are named by their content and
  never change, so they are copied into a `blobs` folder beside it,
  skipping any already there.

      babel_sync eval 'BabelSync.Backup.run("/backups/babelsync")'
  """

  @spec run(Path.t()) :: :ok
  def run(destination) do
    {:ok, _started} = Application.ensure_all_started(:babel_sync)

    if BabelSync.Repo.adapter() != :sqlite do
      raise "BabelSync.Backup covers local mode; back up PostgreSQL with pg_dump and the bucket with its own tools"
    end

    File.mkdir_p!(destination)
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    snapshot = Path.join(destination, "babel_sync-#{stamp}.db")
    snapshot!(snapshot)

    copied = copy_new(Path.join(BabelSync.data_dir(), "blobs"), Path.join(destination, "blobs"))
    IO.puts("wrote #{snapshot} and #{copied} new attachment files")
  end

  defp snapshot!(target) do
    database = Application.fetch_env!(:babel_sync, BabelSync.Repo.SQLite)[:database]
    {:ok, connection} = Exqlite.Sqlite3.open(database, mode: :readonly)

    try do
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
