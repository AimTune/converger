defmodule Converger.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Converger.Repo.{Pools, Pressure}

  @impl true
  def start(_type, _args) do
    # A misconfigured `config :converger, :adapters` fails the boot, not a delivery.
    Converger.Channels.Adapter.validate_registry!()

    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:converger, :repo])
    OpentelemetryEcto.setup([:converger, :background_repo])
    OpentelemetryOban.setup()
    # Oban jobs query the background pool (bulkhead, issue #35).
    :ok = Pools.attach()

    # Node discovery (libcluster). Nothing is started without a
    # CLUSTER_STRATEGY; see Converger.Cluster.
    # Protocol v1 over gRPC (ADR-0056), when GRPC_ENABLED: on its own port,
    # stopped after ConvergerWeb.Drain drained its streams.
    # Event backbone (ADR-0070): subscriptions are declared and broker
    # clients started before Oban runs jobs that publish events.
    children =
      [
        ConvergerWeb.Telemetry,
        Converger.Vault,
        Converger.Repo
      ] ++
        Pools.child_specs() ++
        [
          # Pool wait time for readiness (issue #35).
          Pressure
        ] ++
        Converger.Cluster.child_specs() ++
        [
          {Phoenix.PubSub, name: Converger.PubSub},
          ConvergerWeb.SocketPresence,
          ConvergerWeb.ConversationPresence,
          # Agent groups of channel-scoped connections (hello.group, #64): which
          # connection of a group serves a conversation, across nodes.
          %{
            id: ConvergerWeb.Protocol.AgentGroups,
            start: {:pg, :start_link, [ConvergerWeb.Protocol.AgentGroups]}
          },
          # Native v1 WebSockets and SSE streams, drained by ConvergerWeb.Drain.
          ConvergerWeb.ProtocolConnections,
          # Open client connections, for the connection gauge (ConvergerWeb.Telemetry).
          ConvergerWeb.ClientConnections,
          # Per-node cache of revoked Converger tokens (ADR-0059), before the
          # endpoint so no token is verified without it.
          Converger.Auth.RevocationCache,
          {Task.Supervisor, name: Converger.TaskSupervisor},
          # Per-node cache of provider message templates (WhatsApp HSM).
          Converger.Channels.Templates,
          # Per-node cache of publishable-key origins for CORS (ADR-0074).
          Converger.Channels.PublishableOrigins,
          # Per-node cache of provider tokens and signing keys (Bot Framework).
          Converger.Channels.TokenCache,
          Converger.RateLimit.Supervisor,
          # Per-node cap on the running deliveries of one channel (ADR-0076),
          # before Oban runs delivery jobs.
          Converger.Channels.InFlight,
          # Broker channels (kafka, rabbitmq, nats, redis_streams, mqtt): per-channel publishers, started
          # on first delivery, so before Oban runs delivery jobs.
          {Registry, keys: :unique, name: Converger.Channels.Broker.Registry},
          Converger.Channels.Broker.Publishers
        ] ++
        Converger.Backbone.child_specs() ++
        [
          {Oban, oban_config()}
        ] ++
        Converger.Partitions.boot_children() ++
        Converger.Pipeline.child_specs() ++
        [ConvergerWeb.Endpoint] ++
        mekik_connections() ++
        broker_consumers() ++
        ConvergerWeb.GRPC.child_specs() ++
        [
          # Last: stopped first on shutdown, it flips readiness to 503 and
          # waits before the endpoint drains its sockets.
          ConvergerWeb.Drain
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Converger.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Upstream connections of mekik channels (Mode A of #64) and the relay of
  # the end users' bot-only frames. They create activities, so they start
  # after the endpoint and, on shutdown, stop before it.
  defp mekik_connections,
    do: Converger.Channels.Mekik.Connections.child_specs() ++ [Converger.Channels.Mekik.Relay]

  # Broker channel consumers create activities (PubSub broadcasts through the
  # endpoint), so they start after it and, on shutdown, drain before it stops.
  defp broker_consumers, do: Converger.Channels.Consumers.child_specs()

  @doc """
  The Oban config, with `config :converger, :oban_lifeline` options (set from
  `OBAN_LIFELINE_*` in config/runtime.exs) merged into the
  `Oban.Plugins.Lifeline` plugin, and Oban's queries routed to the background
  pool when it is enabled (`Converger.Repo.Pools.oban_config/1`).
  """
  def oban_config do
    config = :converger |> Application.fetch_env!(Oban) |> Pools.oban_config()

    case Application.get_env(:converger, :oban_lifeline, []) do
      [] -> config
      overrides -> Keyword.update(config, :plugins, [], &override_lifeline(&1, overrides))
    end
  end

  defp override_lifeline(plugins, overrides) when is_list(plugins) do
    Enum.map(plugins, fn
      {Oban.Plugins.Lifeline, opts} -> {Oban.Plugins.Lifeline, Keyword.merge(opts, overrides)}
      plugin -> plugin
    end)
  end

  defp override_lifeline(plugins, _overrides), do: plugins

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ConvergerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
