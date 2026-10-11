defmodule Converger.ClusterTest do
  use ExUnit.Case, async: true

  alias Converger.Cluster

  test "no strategy starts nothing" do
    assert Cluster.topologies([]) == []
    assert Cluster.topologies(strategy: :none) == []
    assert Cluster.child_specs(strategy: :none) == []
    refute Cluster.enabled?(strategy: :none)
  end

  test "kubernetes_dns uses the headless service and the node basename" do
    config = [
      strategy: :kubernetes_dns,
      options: [
        service: "converger-headless.default.svc.cluster.local",
        application_name: "converger",
        polling_interval: nil
      ]
    ]

    assert [
             converger: [
               strategy: Elixir.Cluster.Strategy.Kubernetes.DNS,
               config: [
                 service: "converger-headless.default.svc.cluster.local",
                 application_name: "converger"
               ]
             ]
           ] = Cluster.topologies(config)

    assert [{Elixir.Cluster.Supervisor, [_topologies, [name: Converger.ClusterSupervisor]]}] =
             Cluster.child_specs(config)

    assert Cluster.enabled?(config)
  end

  test "dns, gossip and epmd map to their libcluster strategies" do
    assert [converger: [strategy: Elixir.Cluster.Strategy.DNSPoll, config: _]] =
             Cluster.topologies(
               strategy: :dns,
               options: [query: "converger.internal", node_basename: "converger"]
             )

    assert [converger: [strategy: Elixir.Cluster.Strategy.Gossip, config: [secret: "s"]]] =
             Cluster.topologies(strategy: :gossip, options: [secret: "s"])

    assert [converger: [strategy: Elixir.Cluster.Strategy.Epmd, config: [hosts: [:a@h, :b@h]]]] =
             Cluster.topologies(strategy: :epmd, options: [hosts: [:a@h, :b@h]])

    # Without hosts: every node in the local EPMD.
    assert [converger: [strategy: Elixir.Cluster.Strategy.LocalEpmd, config: [hosts: []]]] =
             Cluster.topologies(strategy: :epmd, options: [hosts: []])
  end

  test "missing required options and unknown strategies fail at boot" do
    assert_raise ArgumentError, ~r/requires :service/, fn ->
      Cluster.topologies(strategy: :kubernetes_dns, options: [application_name: "converger"])
    end

    assert_raise ArgumentError, ~r/requires :query/, fn ->
      Cluster.topologies(strategy: :dns, options: [node_basename: "converger"])
    end

    assert_raise ArgumentError, ~r/invalid cluster strategy/, fn ->
      Cluster.topologies(strategy: :kubernetes)
    end
  end
end
