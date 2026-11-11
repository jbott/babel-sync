defmodule BabelSync.Repo.Postgres do
  use Ecto.Repo,
    otp_app: :babel_sync,
    adapter: Ecto.Adapters.Postgres
end
