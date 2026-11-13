defmodule BabelSync.Cluster.Member do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:name, :string, autogenerate: false}

  schema "cluster_nodes" do
    field :seen_at, :utc_datetime_usec
  end
end
