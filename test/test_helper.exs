excluded =
  if(BabelSync.Chrome.path(), do: [], else: [:browser]) ++
    if(BabelSync.storage() == :local, do: [], else: [:local_storage])

ExUnit.start(exclude: excluded)
Ecto.Adapters.SQL.Sandbox.mode(BabelSync.Repo.active(), :manual)
