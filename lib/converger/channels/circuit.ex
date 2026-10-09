defmodule Converger.Channels.Circuit do
  @moduledoc """
  Per-channel delivery circuit breaker, manual pause and outbound rate limit.

  The breaker state lives on the channel row (`circuit_state`,
  `circuit_changed_at`, `consecutive_failures`), so every node sees the same
  state and the delivery worker gets it for free with the channel it loads.
  Transitions are single conditional `UPDATE`s, so concurrent workers cannot
  open, probe or close a breaker twice.

  States:

    * `closed` - deliveries flow.
    * `open` - opened after `failure_threshold` consecutive transient
      failures, or when the health check turns the channel `unhealthy`.
      Deliveries are parked.
    * `half_open` - one delivery (the probe) was let through after
      `cooldown_ms`. Success closes the breaker, failure re-opens it.
    * `paused` - manual pause (admin UI / tenant API). Deliveries are parked
      until resumed; no probes.

  Parking (`park/3`) snoozes the Oban job for `park_seconds` and drops it to
  priority 3 (fresh jobs use 1), so fresh deliveries of healthy channels in the same queue are
  always fetched first. Closing or resuming releases every parked job at once
  (`release_parked/1`). `Converger.Workers.ChannelCircuitProbeWorker` wakes
  one parked job every `cooldown_ms` while the breaker is open; it becomes the
  half-open probe.

  Configuration (`config :converger, :circuit_breaker, ...`):

    * `failure_threshold` (default `5`)
    * `cooldown_ms` (default `30_000`) - time open before a probe
    * `park_seconds` (default `600`) - how long a parked job sleeps before it
      re-checks on its own (it is released earlier on close/resume)

  Telemetry: `[:converger, :channel, :circuit_opened | :circuit_closed |
  :paused | :resumed]` and `[:converger, :deliveries, :parked |
  :rate_limited]`, all with `%{count: 1}`.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Converger.Channels.{Adapter, Channel, DeliveryError}
  alias Converger.Deliveries.Delivery
  alias Converger.Repo
  alias Converger.Workers.{ActivityDeliveryWorker, ChannelCircuitProbeWorker}

  @parked_priority 3
  @default_priority 1
  @breaker_states ~w(open half_open)

  @defaults [failure_threshold: 5, cooldown_ms: 30_000, park_seconds: 600]

  @doc "Effective breaker configuration."
  def config do
    Keyword.merge(@defaults, Application.get_env(:converger, :circuit_breaker, []))
  end

  @doc "Oban priority given to parked delivery jobs."
  def parked_priority, do: @parked_priority

  # --- Admission (called by the delivery worker before an attempt) ---

  @doc """
  Decide whether a delivery to `channel` may be attempted now.

    * `:ok` - attempt it (closed breaker within its rate limit, or the probe)
    * `{:park, :open | :paused}` - park the job (`park/3`)
    * `{:snooze, seconds}` - the channel's rate limit is exhausted
  """
  def admit(%Channel{circuit_state: "paused"}), do: {:park, :paused}

  def admit(%Channel{circuit_state: state} = channel) when state in @breaker_states do
    if claim_probe(channel), do: :ok, else: {:park, :open}
  end

  def admit(%Channel{} = channel), do: check_rate_limit(channel)

  # The first worker to find an open (or a stale half-open) breaker past its
  # cooldown moves it to half_open and becomes the probe.
  defp claim_probe(%Channel{id: id}) do
    now = now()
    cutoff = DateTime.add(now, -config()[:cooldown_ms], :millisecond)

    {count, _} =
      from(c in Channel,
        where: c.id == ^id and c.circuit_state in @breaker_states,
        where: is_nil(c.circuit_changed_at) or c.circuit_changed_at <= ^cutoff
      )
      |> Repo.update_all(set: [circuit_state: "half_open", circuit_changed_at: now])

    count == 1
  end

  # --- Rate limit ---

  @doc """
  Parse a rate limit such as `"80/s"`, `"1000/m"` or `"5000/h"` into
  `{limit, scale_ms}`. `nil` and `""` mean no limit.
  """
  def parse_rate_limit(nil), do: {:ok, nil}
  def parse_rate_limit(""), do: {:ok, nil}

  def parse_rate_limit(value) when is_binary(value) do
    case Regex.run(~r{\A\s*(\d+)\s*/\s*(s|m|h)\s*\z}, value) do
      [_, limit, unit] ->
        case String.to_integer(limit) do
          0 -> :error
          limit -> {:ok, {limit, unit_ms(unit)}}
        end

      _ ->
        :error
    end
  end

  def parse_rate_limit(_), do: :error

  defp unit_ms("s"), do: 1_000
  defp unit_ms("m"), do: 60_000
  defp unit_ms("h"), do: 3_600_000

  @doc """
  Effective `{limit, scale_ms}` of a channel: its own `rate_limit`, otherwise
  the adapter default (e.g. WhatsApp Meta's 80 messages/s), otherwise `nil`.
  """
  def rate_limit_for(%Channel{rate_limit: value, type: type}) do
    case parse_rate_limit(value) do
      {:ok, {_, _} = spec} -> spec
      _ -> adapter_rate_limit(type)
    end
  end

  defp adapter_rate_limit(type) do
    case Adapter.rate_limit(type) |> parse_rate_limit() do
      {:ok, spec} -> spec
      :error -> nil
    end
  end

  defp check_rate_limit(channel) do
    case rate_limit_for(channel) do
      nil ->
        :ok

      spec ->
        case Converger.RateLimit.check("channel_outbound", channel.id, default: spec) do
          {:allow, _} ->
            :ok

          {:deny, retry_after_ms, _spec} ->
            :telemetry.execute([:converger, :deliveries, :rate_limited], %{count: 1}, %{
              channel_id: channel.id,
              channel_type: channel.type,
              retry_after_ms: retry_after_ms
            })

            {:snooze, max(ceil_div(retry_after_ms, 1000), 1)}
        end
    end
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  # --- Recording outcomes (called by Converger.Pipeline after an adapter call) ---

  @doc """
  Feed an adapter result into the breaker. Successes reset the failure count
  (and close a half-open breaker); transient failures count towards opening
  it. Permanent errors (`retryable?: false`, e.g. an invalid recipient) say
  nothing about the endpoint and are ignored.
  """
  def record(channel, :ok), do: record_success(channel)
  def record(channel, {:ok, _}), do: record_success(channel)
  # Handed off, receipt pending (websocket): the endpoint worked.
  def record(channel, {:pending, _}), do: record_success(channel)
  def record(_channel, {:error, %DeliveryError{retryable?: false}}), do: :ok
  def record(channel, {:error, _}), do: record_failure(channel)

  defp record_success(%Channel{id: id} = channel) do
    # Only a delivery that saw the breaker open/half-open can be the one
    # closing it; on the hot path this is a single no-op UPDATE.
    if channel.circuit_state in @breaker_states, do: close(channel)

    from(c in Channel, where: c.id == ^id and c.consecutive_failures > 0)
    |> Repo.update_all(set: [consecutive_failures: 0])

    :ok
  end

  defp record_failure(%Channel{id: id} = channel) do
    result =
      from(c in Channel,
        where: c.id == ^id,
        select: {c.circuit_state, c.consecutive_failures}
      )
      |> Repo.update_all(inc: [consecutive_failures: 1])

    case result do
      {1, [{"half_open", _}]} ->
        transition(channel, "half_open", "open", :probe_failed)

      {1, [{"closed", failures}]} ->
        if failures >= config()[:failure_threshold],
          do: transition(channel, "closed", "open", :failures)

      _ ->
        :ok
    end

    :ok
  end

  @doc "Open a closed breaker (e.g. the health check found the channel `unhealthy`)."
  def trip(%Channel{} = channel, reason) do
    transition(channel, "closed", "open", reason)
  end

  defp close(channel) do
    transition(channel, @breaker_states, "closed", :probe_succeeded)
  end

  # --- Manual pause / resume ---

  @doc "Pause deliveries to a channel until `resume/1`. Returns the updated channel."
  def pause(%Channel{} = channel) do
    transition(channel, ~w(closed open half_open), "paused", :manual)
    {:ok, Repo.get!(Channel, channel.id)}
  end

  @doc "Resume a paused (or force-close an open) channel and release its parked deliveries."
  def resume(%Channel{} = channel) do
    transition(channel, ~w(paused open half_open), "closed", :manual)
    {:ok, Repo.get!(Channel, channel.id)}
  end

  # Atomically moves the breaker from one of `from` to `to`. Side effects run
  # only for the caller that actually made the transition.
  defp transition(channel, from, to, reason) do
    from = List.wrap(from)
    now = now()

    set =
      [circuit_state: to, circuit_changed_at: now] ++
        if(to == "closed", do: [consecutive_failures: 0], else: [])

    {count, _} =
      from(c in Channel, where: c.id == ^channel.id and c.circuit_state in ^from)
      |> Repo.update_all(set: set)

    if count == 1 do
      after_transition(channel, to, reason, now)
      true
    else
      false
    end
  end

  defp event_for("open", _reason), do: :circuit_opened
  defp event_for("closed", :manual), do: :resumed
  defp event_for("closed", _reason), do: :circuit_closed
  defp event_for("paused", _reason), do: :paused

  defp after_transition(channel, to, reason, now) do
    event = event_for(to, reason)

    :telemetry.execute([:converger, :channel, event], %{count: 1}, %{
      channel_id: channel.id,
      tenant_id: channel.tenant_id,
      channel_type: channel.type,
      reason: reason
    })

    Logger.warning("Channel delivery #{event}",
      channel_id: channel.id,
      tenant_id: channel.tenant_id,
      reason: inspect(reason)
    )

    schedule_follow_up(channel, to)
    broadcast(channel, to, event, reason, now)

    # Automatic transitions are worth an alert; a human pause/resume is not.
    if event in [:circuit_opened, :circuit_closed] and reason != :probe_failed,
      do: send_alert(channel, event, reason, now)

    :ok
  end

  defp schedule_follow_up(channel, "open"),
    do: ChannelCircuitProbeWorker.schedule(channel.id, config()[:cooldown_ms])

  defp schedule_follow_up(channel, "closed"), do: release_parked(channel.id)
  defp schedule_follow_up(_channel, _state), do: :ok

  # --- Parking ---

  @doc """
  Park a delivery job: lower its priority, mark the delivery `paused` and
  return the snooze (seconds, with jitter so parked jobs do not wake together).
  """
  def park(%Oban.Job{} = job, %Channel{} = channel, reason) do
    if job.id && job.priority != @parked_priority do
      from(j in Oban.Job, where: j.id == ^job.id)
      |> Repo.update_all(set: [priority: @parked_priority])
    end

    with %{"activity_id" => activity_id} <- job.args do
      Converger.Deliveries.get_or_create_delivery(activity_id, channel.id)

      from(d in Delivery,
        where: d.activity_id == ^activity_id and d.channel_id == ^channel.id,
        where: d.status == "pending"
      )
      |> Repo.update_all(set: [status: "paused", updated_at: now()])
    end

    :telemetry.execute([:converger, :deliveries, :parked], %{count: 1}, %{
      channel_id: channel.id,
      channel_type: channel.type,
      reason: reason
    })

    park_seconds = config()[:park_seconds]
    park_seconds + :rand.uniform(max(div(park_seconds, 10), 1))
  end

  @doc """
  Make every parked delivery job of a channel available now (breaker closed or
  channel resumed) and move its `paused` deliveries back to `pending`.
  Returns the number of released jobs.
  """
  def release_parked(channel_id) do
    now = now()

    {count, _} =
      channel_id
      |> parked_jobs_query()
      |> Repo.update_all(
        set: [state: "available", scheduled_at: now, priority: @default_priority]
      )

    from(d in Delivery, where: d.channel_id == ^channel_id and d.status == "paused")
    |> Repo.update_all(set: [status: "pending", updated_at: now])

    count
  end

  @doc "Wake one parked job of a channel to act as the half-open probe. Returns 0 or 1."
  def wake_probe(channel_id) do
    ids =
      channel_id
      |> parked_jobs_query()
      |> order_by([j], asc: j.id)
      |> limit(1)
      |> select([j], j.id)

    {count, _} =
      from(j in Oban.Job, where: j.id in subquery(ids))
      |> Repo.update_all(
        set: [state: "available", scheduled_at: now(), priority: @default_priority]
      )

    count
  end

  @doc "Number of parked delivery jobs of a channel."
  def parked_count(channel_id) do
    channel_id |> parked_jobs_query() |> Repo.aggregate(:count)
  end

  defp parked_jobs_query(channel_id) do
    from(j in Oban.Job,
      where: j.worker == ^inspect(ActivityDeliveryWorker),
      where: j.state == "scheduled" and j.priority == ^@parked_priority,
      where: fragment("?->>'channel_id' = ?", j.args, ^to_string(channel_id))
    )
  end

  # --- Notifications ---

  defp broadcast(channel, state, event, reason, at) do
    ConvergerWeb.Endpoint.broadcast!("channel_health", "circuit_changed", %{
      channel_id: channel.id,
      tenant_id: channel.tenant_id,
      circuit_state: state,
      event: event,
      reason: reason,
      changed_at: at
    })
  end

  defp send_alert(channel, event, reason, at) do
    with %{alert_webhook_url: url} when is_binary(url) and url != "" <-
           Repo.get(Converger.Tenants.Tenant, channel.tenant_id) do
      payload = %{
        event: "channel.#{event}",
        channel_id: channel.id,
        channel_name: channel.name,
        tenant_id: channel.tenant_id,
        reason: to_string(reason),
        changed_at: DateTime.to_iso8601(at)
      }

      Task.start(fn ->
        case Converger.HTTP.post(url, json: payload, receive_timeout: 10_000) do
          {:ok, %{status: status}} when status in 200..299 ->
            :ok

          other ->
            Logger.warning(
              "Circuit alert webhook failed for channel #{channel.id}: #{inspect(other)}"
            )
        end
      end)
    end

    :ok
  end

  defp now, do: DateTime.utc_now()
end
