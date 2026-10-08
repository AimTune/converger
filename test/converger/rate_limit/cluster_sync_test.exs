defmodule Converger.RateLimit.ClusterSyncTest do
  # Two sync processes on one PubSub topic, each with its own counter table,
  # stand in for two nodes of a cluster.
  use ExUnit.Case, async: false

  alias Converger.RateLimit.{ClusterSync, Local, NodeB}

  @scale :timer.hours(1)

  setup do
    topic = "rate_limit_test:#{System.unique_integer([:positive])}"

    start_supervised!({NodeB, clean_period: 60_000})

    start_supervised!(
      {ClusterSync, name: :sync_node_a, local: Local, topic: topic, interval_ms: 60_000},
      id: :sync_node_a
    )

    start_supervised!(
      {ClusterSync, name: :sync_node_b, local: NodeB, topic: topic, interval_ms: 60_000},
      id: :sync_node_b
    )

    %{key: "cluster-test:#{System.unique_integer([:positive])}", topic: topic}
  end

  # A hit on "node A": count locally, record for replication.
  defp hit_a(key, limit) do
    result = Local.hit(key, @scale, limit)
    ClusterSync.record(:sync_node_a, key, @scale, 1)
    result
  end

  defp hit_b(key, limit) do
    result = NodeB.hit(key, @scale, limit)
    ClusterSync.record(:sync_node_b, key, @scale, 1)
    result
  end

  # Flushing and then a sync call on the receiver guarantees the batch was
  # processed (messages between two processes are ordered).
  defp sync(from, to) do
    :ok = ClusterSync.flush(from)
    :ok = ClusterSync.flush(to)
  end

  test "limits apply across nodes", %{key: key} do
    assert {:allow, 1} = hit_a(key, 3)
    assert {:allow, 2} = hit_a(key, 3)
    sync(:sync_node_a, :sync_node_b)

    assert NodeB.get(key, @scale) == 2
    assert {:allow, 3} = hit_b(key, 3)
    assert {:deny, _} = hit_b(key, 3)

    sync(:sync_node_b, :sync_node_a)
    assert Local.get(key, @scale) == 4
    assert {:deny, _} = hit_a(key, 3)
  end

  test "broadcasts batched deltas once per flush", %{key: key, topic: topic} do
    Phoenix.PubSub.subscribe(Converger.PubSub, topic)

    for _ <- 1..5, do: hit_a(key, 100)
    :ok = ClusterSync.flush(:sync_node_a)

    assert_receive {:rate_limit_sync, [{^key, @scale, _window, 5}]}

    # nothing pending: no second broadcast
    :ok = ClusterSync.flush(:sync_node_a)
    refute_receive {:rate_limit_sync, _}, 50
  end

  test "drops deltas for windows that already ended", %{key: key, topic: topic} do
    stale_window = div(System.system_time(:millisecond), @scale) - 1

    Phoenix.PubSub.broadcast(
      Converger.PubSub,
      topic,
      {:rate_limit_sync, [{key, @scale, stale_window, 10}]}
    )

    :ok = ClusterSync.flush(:sync_node_b)

    assert NodeB.get(key, @scale) == 0
  end
end
