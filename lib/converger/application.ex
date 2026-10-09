defmodule Converger.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:converger, :repo])
    OpentelemetryOban.setup()

    children =
      [
        ConvergerWeb.Telemetry,
        Converger.Vault,
        Converger.Repo,
        {DNSCluster, query: Application.get_env(:converger, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Converger.PubSub},
        ConvergerWeb.SocketPresence,
        Converger.RateLimit.Supervisor,
        {Oban, oban_config()}
      ] ++
        Converger.Pipeline.child_specs() ++
        [
          ConvergerWeb.Endpoint,
          # Last: stopped first on shutdown, it flips readiness to 503 and
          # waits before the endpoint drains its sockets.
          ConvergerWeb.Drain
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Converger.Supervisor]
    Supervisor.start_link(children, opts)
  end

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
