defmodule BabelSync.Repo.SQLite do
  use Ecto.Repo,
    otp_app: :babel_sync,
    adapter: Ecto.Adapters.SQLite3
end
