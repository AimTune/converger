defmodule Converger.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # A misconfigured `config :converger, :adapters` fails the boot, not a delivery.
    Converger.Channels.Adapter.validate_registry!()

    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:converger, :repo])
    OpentelemetryOban.setup()

    # Node discovery (libcluster). Nothing is started without a
    # CLUSTER_STRATEGY; see Converger.Cluster.
    children =
      [
        ConvergerWeb.Telemetry,
        Converger.Vault,
        Converger.Repo
      ] ++
        Converger.Cluster.child_specs() ++
        [
          {Phoenix.PubSub, name: Converger.PubSub},
          ConvergerWeb.SocketPresence,
          ConvergerWeb.ConversationPresence,
          # Native v1 WebSockets and SSE streams, drained by ConvergerWeb.Drain.
          ConvergerWeb.ProtocolConnections,
          # Open client connections, for the connection gauge (ConvergerWeb.Telemetry).
          ConvergerWeb.ClientConnections,
          {Task.Supervisor, name: Converger.TaskSupervisor},
          # Per-node cache of provider message templates (WhatsApp HSM).
          Converger.Channels.Templates,
          Converger.RateLimit.Supervisor,
          # Broker channels (kafka, rabbitmq): per-channel publishers, started
          # on first delivery, so before Oban runs delivery jobs.
          {Registry, keys: :unique, name: Converger.Channels.Broker.Registry},
          Converger.Channels.Broker.Publishers,
          {Oban, oban_config()}
        ] ++
        Converger.Partitions.boot_children() ++
        Converger.Pipeline.child_specs() ++
        [ConvergerWeb.Endpoint] ++
        broker_consumers() ++
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

  # Broker channel consumers create activities (PubSub broadcasts through the
  # endpoint), so they start after it and, on shutdown, drain before it stops.
  defp broker_consumers, do: Converger.Channels.Consumers.child_specs()

  @doc """
  The Oban config, with `config :converger, :oban_lifeline` options (set from
  `OBAN_LIFELINE_*` in config/runtime.exs) merged into the
  `Oban.Plugins.Lifeline` plugin.
  """
  def oban_config do
    config = Application.fetch_env!(:converger, Oban)

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
