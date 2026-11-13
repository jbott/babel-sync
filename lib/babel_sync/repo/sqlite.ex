defmodule BabelSync.Repo.SQLite do
  @moduledoc """
  The repository in local mode, on SQLite.
  """

  use Ecto.Repo,
    otp_app: :babel_sync,
    adapter: Ecto.Adapters.SQLite3

  alias Exqlite.Sqlite3

  @impl true
  def init(_context, config) do
    database = Keyword.fetch!(config, :database)
    File.mkdir_p!(Path.dirname(database))

    {:ok, connection} = Sqlite3.open(database)
    :ok = Sqlite3.execute(connection, "PRAGMA busy_timeout = 5000")
    :ok = Sqlite3.execute(connection, "PRAGMA journal_mode = WAL")
    :ok = Sqlite3.close(connection)

    {:ok, config}
  end
end
