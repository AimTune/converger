defmodule ConvergerWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  require Logger

  # Histogram buckets, in milliseconds.
  @request_buckets [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10_000]
  @delivery_buckets [10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10_000, 30_000]
  @lag_buckets [50, 100, 250, 500, 1000, 2500, 5000, 10_000, 30_000, 60_000, 300_000, 900_000]
  @db_buckets [0.5, 1, 2.5, 5, 10, 25, 50, 100, 250, 500, 1000]

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    # Metrics are aggregated in a TelemetryMetricsPrometheus.Core registry and
    # served on the main port at /metrics (ConvergerWeb.Plugs.Metrics, behind
    # METRICS_TOKEN / METRICS_ALLOWED_IPS). A separate, unauthenticated
    # listener is only started when PROMETHEUS_PORT is set explicitly.
    standalone_listener =
      case Application.get_env(:converger, :prometheus_port) do
        port when is_integer(port) ->
          [
            Supervisor.child_spec(
              {Bandit,
               plug: {ConvergerWeb.Plugs.Metrics, standalone: true},
               port: port,
               startup_log: false},
              id: :prometheus_listener
            )
          ]

        _ ->
          []
      end

    children =
      [
        # Telemetry poller will execute the given period measurements
        # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
        {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
        {TelemetryMetricsPrometheus.Core,
         metrics: metrics(), name: ConvergerWeb.Plugs.Metrics.registry()}
      ] ++ database_poller() ++ standalone_listener

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      last_value("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: @request_buckets]
      ),
      last_value("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      distribution("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @request_buckets]
      ),
      distribution("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @request_buckets]
      ),
      last_value("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      last_value("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      distribution("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @request_buckets]
      ),

      # Database Metrics
      distribution("converger.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements",
        reporter_options: [buckets: @db_buckets]
      ),
      last_value("converger.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      last_value("converger.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      distribution("converger.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection (pool saturation)",
        reporter_options: [buckets: @db_buckets]
      ),
      last_value("converger.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),
      distribution("converger.background_repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time Oban jobs spent waiting for a background pool connection",
        reporter_options: [buckets: @db_buckets]
      ),
      # Database pressure (Converger.Repo.Pressure, issue #35)
      last_value("converger.repo.pool.queue_time_ms",
        description: "Average wait for an interactive pool connection over the last window"
      ),
      counter("converger.db.unavailable.count",
        tags: [:source],
        description:
          "Requests, joins and frames answered as retryable because the database was unavailable"
      ),

      # VM Metrics
      last_value("vm.memory.total", unit: {:byte, :kilobyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),

      # Oban
      distribution("oban.job.stop.duration",
        tags: [:queue, :worker, :state],
        tag_values: &oban_tags/1,
        unit: {:native, :millisecond},
        reporter_options: [buckets: @delivery_buckets]
      ),
      distribution("oban.job.exception.duration",
        tags: [:queue, :worker, :state],
        tag_values: &oban_tags/1,
        unit: {:native, :millisecond},
        reporter_options: [buckets: @delivery_buckets]
      ),
      last_value("converger.oban.queue.depth",
        tags: [:queue, :state],
        description: "Oban jobs per queue and state (polled)"
      ),

      # Broadway (Converger.Pipeline.Broadway backend)
      distribution("broadway.batch_processor.stop.duration",
        tags: [:topology_name],
        unit: {:native, :millisecond},
        reporter_options: [buckets: @delivery_buckets]
      ),
      counter("broadway.processor.message.exception.count", tags: [:topology_name]),

      # Delivery SLO (Converger.Telemetry)
      counter("converger.delivery.attempt.count",
        tags: [:channel_type, :retry],
        description: "Delivery attempts; retry=true for every attempt after the first"
      ),
      distribution("converger.delivery.stop.duration",
        tags: delivery_tags([:channel_type, :status]),
        unit: {:native, :millisecond},
        description: "Adapter call latency per attempt, by outcome (sent, pending, failed, dead)",
        reporter_options: [buckets: @delivery_buckets]
      ),
      counter("converger.delivery.exception.count", tags: [:channel_type, :kind]),
      distribution("converger.pipeline.lag.duration",
        tags: delivery_tags([:channel_type, :retry]),
        unit: :millisecond,
        description: "Activity inserted_at to delivery sent (or handed off)",
        reporter_options: [buckets: @lag_buckets]
      ),
      counter("converger.deliveries.dead_lettered.count"),
      sum("converger.deliveries.retried.count", reporter_options: [prometheus_type: :counter]),
      last_value("converger.deliveries.dead_letters.size",
        tags: [:channel_type],
        description: "Dead-lettered (failed) deliveries waiting for a replay (polled)"
      ),
      counter("converger.inbound.received.count",
        tags: delivery_tags([:channel_type, :outcome])
      ),
      # Broker channel consumers (Converger.Channels.Broker)
      counter("converger.broker.dead_lettered.count",
        tags: [:channel_type, :reason],
        description: "Inbound broker messages moved to the channel's dead-letter topic or queue"
      ),
      counter("converger.broker.retry.count",
        tags: [:channel_type],
        description: "Inbound broker messages retried in place after a transient failure"
      ),

      # Realtime connections (ConvergerWeb.ClientConnections)
      last_value("converger.ws.connections.count",
        tags: [:socket, :transport],
        description: "Open client connections on this node (polled)"
      ),
      counter("converger.ws.connected.count", tags: [:socket, :transport]),
      counter("converger.ws.disconnected.count", tags: [:socket, :transport]),
      sum("converger.ws.frame.count",
        tags: [:socket, :transport, :direction],
        reporter_options: [prometheus_type: :counter]
      ),

      # Custom App Metrics
      counter("converger.activities.create.count"),
      # Typed messages of a type outside the vocabulary (#68); no tag: the
      # type names are client-chosen.
      counter("converger.activities.unknown_type.count"),
      counter("converger.rate_limit.exceeded.count", tags: [:bucket]),
      # Delivery circuit breaker (Converger.Channels.Circuit)
      counter("converger.circuit.state_change.count", tags: [:channel_type, :to, :reason]),
      last_value("converger.channels.circuit.count",
        tags: [:channel_type, :state],
        description: "Channels whose breaker is open, half open or paused (polled)"
      ),
      counter("converger.channel.circuit_opened.count", tags: [:channel_type, :reason]),
      counter("converger.channel.circuit_closed.count", tags: [:channel_type]),
      counter("converger.channel.paused.count", tags: [:channel_type]),
      counter("converger.channel.resumed.count", tags: [:channel_type]),
      counter("converger.deliveries.parked.count", tags: [:channel_type, :reason]),
      counter("converger.deliveries.rate_limited.count", tags: [:channel_type]),
      counter("converger.socket.limit.count", tags: [:reason]),
      counter("phoenix.socket_connected.count"),
      counter("phoenix.channel_joined.count"),

      # Counters for Dashboard
      counter("phoenix.http.request_count",
        event_name: [:phoenix, :endpoint, :stop],
        tags: [:status],
        tag_values: &http_tags/1
      ),
      counter("converger.repo.query_count",
        event_name: [:converger, :repo, :query]
      )
    ]
  end

  # `tenant_id` multiplies every delivery series by the number of tenants:
  # opt in with `config :converger, :metrics, tenant_label: true`.
  defp delivery_tags(tags) do
    if Application.get_env(:converger, :metrics, [])[:tenant_label],
      do: tags ++ [:tenant_id],
      else: tags
  end

  defp oban_tags(%{job: job, state: state}),
    do: %{queue: job.queue, worker: job.worker, state: state}

  defp http_tags(%{conn: conn}), do: %{status: conn.status}

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      {__MODULE__, :safely, [ConvergerWeb.ClientConnections, :measure]}
    ]
  end

  # Gauges read from the database (queue depth, dead letters, open circuits),
  # every `:poll_interval_ms`. `poll_interval_ms: false` turns them off (test).
  defp database_poller do
    case Keyword.get(Application.get_env(:converger, :metrics, []), :poll_interval_ms, 15_000) do
      false ->
        []

      period ->
        [
          Supervisor.child_spec(
            {:telemetry_poller,
             name: :converger_database_poller,
             period: period,
             measurements: [
               {__MODULE__, :safely, [Converger.Telemetry, :measure_queues]},
               {__MODULE__, :safely, [Converger.Telemetry, :measure_storage]}
             ]},
            id: :converger_database_poller
          )
        ]
    end
  end

  @doc false
  # `:telemetry_poller` drops a measurement for good the first time it raises,
  # so a database blip (or the Repo not being up yet at boot) would silence a
  # gauge until the next restart. A failed poll is skipped instead.
  def safely(module, function) do
    apply(module, function, [])
  rescue
    error ->
      Logger.debug("Telemetry poll #{inspect(module)}.#{function} failed: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("Telemetry poll #{inspect(module)}.#{function} failed: #{inspect(reason)}")
      :ok
  end
end
