defmodule BabelSync.ClusterTest do
  use BabelSync.DataCase, async: false

  alias BabelSync.Cluster

  test "a server sees the others that announced themselves lately" do
    now = DateTime.utc_now()
    :ok = Cluster.announce("a@10.0.0.1", now)
    :ok = Cluster.announce("b@10.0.0.2", now)
    :ok = Cluster.announce("gone@10.0.0.3", DateTime.add(now, -120, :second))

    assert Cluster.members(now) == ["a@10.0.0.1", "b@10.0.0.2"]
  end

  test "a server that keeps announcing itself stays, and one that withdraws goes at once" do
    now = DateTime.utc_now()
    :ok = Cluster.announce("a@10.0.0.1", DateTime.add(now, -120, :second))
    :ok = Cluster.announce("a@10.0.0.1", now)
    :ok = Cluster.announce("b@10.0.0.2", now)
    :ok = Cluster.withdraw("b@10.0.0.2")

    assert Cluster.members(now) == ["a@10.0.0.1"]
  end

  test "a server on its own, or one that keeps its data on disk, does not look for others" do
    refute Cluster.enabled?()
  end
end
