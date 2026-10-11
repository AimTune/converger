defmodule Converger.Cluster do
  @moduledoc """
  Node discovery for multi-node deployments, built on `libcluster`.

  The topology is selected at boot from `config :converger, Converger.Cluster`
  (set from `CLUSTER_STRATEGY` and friends in `config/runtime.exs`):

  | `:strategy`        | libcluster strategy                  | Typical platform                  |
  | ------------------ | ------------------------------------ | --------------------------------- |
  | `:none` (default)  | none, the node runs alone            | single node, dev, test            |
  | `:kubernetes_dns`  | `Cluster.Strategy.Kubernetes.DNS`    | Kubernetes (headless service)     |
  | `:dns`             | `Cluster.Strategy.DNSPoll`           | Fly.io, ECS service discovery     |
  | `:gossip`          | `Cluster.Strategy.Gossip`            | docker compose, one L2 network    |
  | `:epmd`            | `Cluster.Strategy.Epmd` (`:hosts`) or `Cluster.Strategy.LocalEpmd` | local development |

  `:options` is passed to the strategy as its `config:` (libcluster's own
  option names, e.g. `:service`, `:application_name`, `:query`,
  `:node_basename`, `:polling_interval`, `:secret`, `:hosts`):

      config :converger, Converger.Cluster,
        strategy: :kubernetes_dns,
        options: [service: "converger-headless.default.svc.cluster.local", application_name: "converger"]

  Connected nodes share `Converger.PubSub` (WebSocket broadcasts, presence,
  rate-limit sync). Oban coordinates through Postgres and needs no
  distribution. See docs/operations/clustering.md.
  """

  @strategies %{
    kubernetes_dns: Cluster.Strategy.Kubernetes.DNS,
    dns: Cluster.Strategy.DNSPoll,
    gossip: Cluster.Strategy.Gossip,
    epmd: Cluster.Strategy.Epmd
  }

  @required %{
    kubernetes_dns: [:service, :application_name],
    dns: [:query, :node_basename],
    gossip: [],
    epmd: []
  }

  @type strategy :: :none | :kubernetes_dns | :dns | :gossip | :epmd

  @doc "The supported `:strategy` values."
  @spec strategies() :: [strategy()]
  def strategies, do: [:none | Map.keys(@strategies)]

  @doc "Whether node discovery is configured (strategy other than `:none`)."
  @spec enabled?(keyword()) :: boolean()
  def enabled?(config \\ config()), do: Keyword.get(config, :strategy, :none) != :none

  @doc """
  Child specs to start under the application supervisor: a
  `Cluster.Supervisor` when a strategy is configured, otherwise nothing.
  """
  @spec child_specs(keyword()) :: [Supervisor.child_spec() | {module(), term()}]
  def child_specs(config \\ config()) do
    case topologies(config) do
      [] -> []
      topologies -> [{Cluster.Supervisor, [topologies, [name: Converger.ClusterSupervisor]]}]
    end
  end

  @doc """
  Builds the libcluster topologies for `config`. Raises `ArgumentError` for
  an unknown strategy or a missing required option, so a misconfigured
  release fails at boot instead of silently running unclustered.
  """
  @spec topologies(keyword()) :: keyword()
  def topologies(config) do
    case Keyword.get(config, :strategy, :none) do
      :none ->
        []

      strategy when is_map_key(@strategies, strategy) ->
        opts =
          config
          |> Keyword.get(:options, [])
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)

        validate!(strategy, opts)
        [converger: [strategy: module(strategy, opts), config: opts]]

      other ->
        raise ArgumentError,
              "invalid cluster strategy #{inspect(other)}, expected one of #{inspect(strategies())}"
    end
  end

  # Without explicit hosts, connect to every node registered in the local
  # EPMD (several `iex --sname` nodes on one machine).
  defp module(:epmd, opts) do
    if Keyword.get(opts, :hosts, []) == [],
      do: Cluster.Strategy.LocalEpmd,
      else: Cluster.Strategy.Epmd
  end

  defp module(strategy, _opts), do: Map.fetch!(@strategies, strategy)

  defp validate!(strategy, opts) do
    missing =
      Enum.reject(Map.fetch!(@required, strategy), &(Keyword.get(opts, &1) not in [nil, ""]))

    if missing != [] do
      raise ArgumentError,
            "cluster strategy #{inspect(strategy)} requires #{Enum.map_join(missing, ", ", &inspect/1)}"
    end

    :ok
  end

  defp config, do: Application.get_env(:converger, __MODULE__, [])
end
