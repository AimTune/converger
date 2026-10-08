defmodule Converger.RateLimit.Supervisor do
  @moduledoc """
  Starts the rate-limit counters, the tenant override cache and, when the
  `:cluster` backend is configured, the PubSub counter replication.

  Must be started after `Converger.PubSub`.
  """

  use Supervisor

  alias Converger.RateLimit

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    config = Application.get_env(:converger, RateLimit, [])
    backend = Keyword.get(config, :backend, :local)

    unless backend in [:local, :cluster] do
      raise ArgumentError,
            "invalid :backend #{inspect(backend)} for Converger.RateLimit, expected :local or :cluster"
    end

    :persistent_term.put({RateLimit, :backend}, backend)

    sync_children =
      if backend == :cluster do
        [
          {RateLimit.ClusterSync,
           name: RateLimit.ClusterSync,
           local: RateLimit.Local,
           interval_ms: Keyword.get(config, :sync_interval_ms, 100)}
        ]
      else
        []
      end

    children =
      [
        {RateLimit.Local, clean_period: Keyword.get(config, :clean_period_ms, 60_000)},
        RateLimit.Overrides
      ] ++ sync_children

    Supervisor.init(children, strategy: :one_for_one)
  end
end
