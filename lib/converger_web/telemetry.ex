defmodule ConvergerWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    port = Application.get_env(:converger, :prometheus_port, 9568)

    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      # Add reporters as children of your supervision tree.
      {TelemetryMetricsPrometheus, [metrics: metrics(), port: port]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      last_value("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      last_value("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      last_value("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      last_value("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      last_value("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      last_value("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      last_value("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      last_value("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      last_value("converger.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      last_value("converger.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      last_value("converger.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      last_value("converger.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      last_value("converger.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),
      last_value("oban.job.exception.duration", unit: {:native, :millisecond}),

      # Custom App Metrics
      counter("converger.activities.create.count"),
      counter("phoenix.socket_connected.count"),
      counter("phoenix.channel_joined.count"),

      # Counters for Dashboard
      counter("phoenix.http.request_count",
        event_name: [:phoenix, :endpoint, :stop],
        tags: [:status]
      ),
      counter("converger.repo.query_count",
        event_name: [:converger, :repo, :query]
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {ConvergerWeb, :count_users, []}
    ]
  end
end
