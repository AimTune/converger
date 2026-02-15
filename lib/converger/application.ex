defmodule Converger.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:converger, :repo])

    children = [
      ConvergerWeb.Telemetry,
      Converger.Repo,
      {DNSCluster, query: Application.get_env(:converger, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Converger.PubSub},
      {Oban, Application.fetch_env!(:converger, Oban)},
      # Start a worker by calling: Converger.Worker.start_link(arg)
      # {Converger.Worker, arg},
      # Start to serve requests, typically the last entry
      ConvergerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Converger.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ConvergerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
