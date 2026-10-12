defmodule Converger.Telemetry do
  @moduledoc """
  Delivery, pipeline and connection telemetry: the events behind the SLO
  metrics of `ConvergerWeb.Telemetry` and the Grafana dashboards.

  | Event | Measurements | Metadata |
  | --- | --- | --- |
  | `[:converger, :delivery, :attempt]` | `count` | `channel_id`, `channel_type`, `tenant_id`, `delivery_id`, `activity_id`, `attempt`, `retry` |
  | `[:converger, :delivery, :stop]` | `duration` (native) | as `:attempt`, plus `status` (`sent`, `pending`, `failed`, `dead`) |
  | `[:converger, :delivery, :exception]` | `duration` (native) | as `:attempt`, plus `kind`, `reason` |
  | `[:converger, :pipeline, :lag]` | `duration` (ms) | as `:attempt`, plus `status` (`sent`, `pending`) |
  | `[:converger, :inbound, :received]` | `count` | `channel_id`, `channel_type`, `tenant_id`, `outcome` |
  | `[:converger, :ws, :connected]`, `[:converger, :ws, :disconnected]` | `count` | `socket`, `transport` |
  | `[:converger, :ws, :frame]` | `count` | `socket`, `transport`, `direction` (`in`, `out`) |
  | `[:converger, :circuit, :state_change]` | `count` | `channel_id`, `channel_type`, `tenant_id`, `to`, `reason` |

  The adapter call of every delivery attempt also runs inside an
  OpenTelemetry span `converger.delivery`, a child of the Oban job span.

  `measure_queues/0` and `measure_storage/0` are polled by
  `ConvergerWeb.Telemetry` and emit the gauges that need the database:

  | Event | Measurements | Metadata |
  | --- | --- | --- |
  | `[:converger, :oban, :queue]` | `depth` | `queue`, `state` (`available`, `scheduled`, `retryable`, `executing`) |
  | `[:converger, :deliveries, :dead_letters]` | `size` | `channel_type` |
  | `[:converger, :channels, :circuit]` | `count` | `channel_type`, `state` (`open`, `half_open`, `paused`) |

  Every known queue/state and channel type is reported, with 0 when empty,
  so a gauge never keeps a stale value after its rows are gone.
  """

  require OpenTelemetry.Tracer, as: Tracer

  import Ecto.Query, only: [from: 2]

  alias Converger.Channels.Channel
  alias Converger.Deliveries.Delivery
  alias Converger.Repo

  @queue_states ~w(available scheduled retryable executing)
  @open_circuit_states ~w(open half_open paused)

  @doc """
  Runs one adapter call of a delivery attempt: emits
  `[:converger, :delivery, :attempt]`, wraps the call in the
  `converger.delivery` OpenTelemetry span and times it. Returns
  `{result, duration}` (native units) for `delivery_stop/4`.

  An exception emits `[:converger, :delivery, :exception]` and is re-raised.
  """
  def delivery_attempt(delivery, activity, channel, fun) do
    metadata = delivery_metadata(delivery, activity, channel)
    :telemetry.execute([:converger, :delivery, :attempt], %{count: 1}, metadata)
    start = System.monotonic_time()

    Tracer.with_span "converger.delivery", %{attributes: span_attributes(metadata)} do
      try do
        result = fun.()
        if failure?(result), do: Tracer.set_status(:error, inspect(elem(result, 1)))
        {result, System.monotonic_time() - start}
      catch
        kind, reason ->
          :telemetry.execute(
            [:converger, :delivery, :exception],
            %{duration: System.monotonic_time() - start},
            Map.merge(metadata, %{kind: kind, reason: reason})
          )

          Tracer.set_status(:error, Exception.format_banner(kind, reason))
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  @doc """
  Emits `[:converger, :delivery, :stop]` for an attempt timed by
  `delivery_attempt/4`, and `[:converger, :pipeline, :lag]` when the
  activity left the pipeline (sent, or handed off to a WebSocket channel).

  `outcome` is what `Converger.Pipeline.deliver/2` returns for the attempt;
  it tells a retryable failure from a dead-lettered one.
  """
  def delivery_stop(delivery, activity, channel, {result, duration}, outcome) do
    metadata = delivery_metadata(delivery, activity, channel)
    status = delivery_status(result, outcome)

    :telemetry.execute(
      [:converger, :delivery, :stop],
      %{duration: duration},
      Map.put(metadata, :status, status)
    )

    if status in ["sent", "pending"] do
      lag = DateTime.diff(DateTime.utc_now(), activity.inserted_at, :millisecond)

      :telemetry.execute(
        [:converger, :pipeline, :lag],
        %{duration: max(lag, 0)},
        Map.put(metadata, :status, status)
      )
    end

    :ok
  end

  defp delivery_status(:ok, _outcome), do: "sent"
  defp delivery_status({:ok, _meta}, _outcome), do: "sent"
  defp delivery_status({:pending, _meta}, _outcome), do: "pending"
  defp delivery_status(_error, {:error, {:dead_lettered, _}}), do: "dead"
  defp delivery_status(_error, _outcome), do: "failed"

  defp failure?({:error, _}), do: true
  defp failure?(_result), do: false

  defp delivery_metadata(delivery, activity, channel) do
    attempt = (delivery.attempts || 0) + 1

    %{
      channel_id: channel.id,
      channel_type: channel.type,
      tenant_id: channel.tenant_id,
      delivery_id: delivery.id,
      activity_id: activity.id,
      attempt: attempt,
      retry: attempt > 1
    }
  end

  defp span_attributes(metadata) do
    %{
      "converger.channel.id": metadata.channel_id,
      "converger.channel.type": metadata.channel_type,
      "converger.tenant.id": metadata.tenant_id,
      "converger.delivery.id": metadata.delivery_id,
      "converger.activity.id": metadata.activity_id,
      "converger.delivery.attempt": metadata.attempt
    }
  end

  @doc """
  Emits `[:converger, :inbound, :received]` for a message received on an
  inbound channel. `outcome` is `created`, `duplicate`, `rejected` or `error`.
  """
  def inbound_received(%Channel{} = channel, outcome) do
    :telemetry.execute([:converger, :inbound, :received], %{count: 1}, %{
      channel_id: channel.id,
      channel_type: channel.type,
      tenant_id: channel.tenant_id,
      outcome: outcome
    })
  end

  @doc "Emits `[:converger, :ws, :frame]` for `count` frames on a client connection."
  def ws_frame(socket, transport, direction, count \\ 1) do
    :telemetry.execute([:converger, :ws, :frame], %{count: count}, %{
      socket: socket,
      transport: transport,
      direction: direction
    })
  end

  @doc "Polled: Oban job counts per queue and state."
  def measure_queues do
    counts =
      from(j in Oban.Job,
        where: j.state in @queue_states,
        group_by: [j.queue, j.state],
        select: {{j.queue, j.state}, count(j.id)}
      )
      |> Repo.all()
      |> Map.new()

    queues =
      Application.get_env(:converger, Oban, [])
      |> Keyword.get(:queues, [])
      |> Enum.map(fn {queue, _limit} -> to_string(queue) end)

    keys = Enum.uniq(for(q <- queues, s <- @queue_states, do: {q, s}) ++ Map.keys(counts))

    for {queue, state} = key <- keys do
      :telemetry.execute([:converger, :oban, :queue], %{depth: Map.get(counts, key, 0)}, %{
        queue: queue,
        state: state
      })
    end

    :ok
  end

  @doc "Polled: dead-letter size per channel type, and channels whose breaker is not closed."
  def measure_storage do
    dead_letters =
      from(d in Delivery,
        join: c in Channel,
        on: c.id == d.channel_id,
        where: d.status == "failed",
        group_by: c.type,
        select: {c.type, count(d.id)}
      )
      |> Repo.all()
      |> Map.new()

    for type <- Channel.channel_types() do
      :telemetry.execute(
        [:converger, :deliveries, :dead_letters],
        %{size: Map.get(dead_letters, type, 0)},
        %{channel_type: type}
      )
    end

    circuits =
      from(c in Channel,
        where: c.circuit_state in @open_circuit_states,
        group_by: [c.type, c.circuit_state],
        select: {{c.type, c.circuit_state}, count(c.id)}
      )
      |> Repo.all()
      |> Map.new()

    for type <- Channel.channel_types(), state <- @open_circuit_states do
      :telemetry.execute(
        [:converger, :channels, :circuit],
        %{count: Map.get(circuits, {type, state}, 0)},
        %{channel_type: type, state: state}
      )
    end

    :ok
  end
end
