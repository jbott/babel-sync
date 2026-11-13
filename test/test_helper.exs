excluded =
  if(BabelSync.Chrome.path(), do: [], else: [:browser]) ++
    if(BabelSync.storage() == :local, do: [], else: [:local_storage])

ExUnit.start(exclude: excluded)
Ecto.Adapters.SQL.Sandbox.mode(BabelSync.Repo.active(), :manual)

if BabelSync.storage() == :local do
  for left_by_earlier_runs <- ["blobs", "uploads"] do
    File.rm_rf!(Path.join(BabelSync.data_dir(), left_by_earlier_runs))
  end
end
