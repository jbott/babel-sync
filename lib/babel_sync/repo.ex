defmodule BabelSync.Repo do
  @moduledoc """
  Facade over the repo selected at boot by `BABELSYNC_STORAGE`.

  Ecto fixes a repo's adapter at compile time, so local mode (SQLite) and
  remote mode (Postgres) are two repo modules. Application code calls
  `BabelSync.Repo`, which forwards to whichever one is running.
  """

  @lifecycle [:child_spec, :start_link, :stop, :init, :config, :__adapter__]

  @spec active() :: module()
  def active, do: Application.fetch_env!(:babel_sync, :repo)

  @spec adapter() :: :sqlite | :postgres
  def adapter do
    case active() do
      BabelSync.Repo.SQLite -> :sqlite
      BabelSync.Repo.Postgres -> :postgres
    end
  end

  Code.ensure_compiled!(BabelSync.Repo.Postgres)

  for {name, arity} <- BabelSync.Repo.Postgres.__info__(:functions),
      name not in @lifecycle,
      not String.starts_with?(Atom.to_string(name), "__") do
    args = Macro.generate_arguments(arity, __MODULE__)

    def unquote(name)(unquote_splicing(args)) do
      active().unquote(name)(unquote_splicing(args))
    end
  end
end
