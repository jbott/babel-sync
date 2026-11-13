defmodule BabelSync.Repo.Postgres do
  @moduledoc """
  The repository in remote mode, on PostgreSQL.
  """

  use Ecto.Repo,
    otp_app: :babel_sync,
    adapter: Ecto.Adapters.Postgres
end
