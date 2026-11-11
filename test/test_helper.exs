ExUnit.start(exclude: if(BabelSync.Chrome.path(), do: [], else: [:browser]))
Ecto.Adapters.SQL.Sandbox.mode(BabelSync.Repo.active(), :manual)
