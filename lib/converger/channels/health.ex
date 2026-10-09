defmodule Converger.Channels.Health do
  @moduledoc """
  Channel health monitoring based on delivery failure rates.

  Health is computed from delivery success/failure ratios over a rolling window:
  - healthy:   failure rate < 10%
  - degraded:  failure rate 10% – 50%
  - unhealthy: failure rate > 50%
  - unknown:   no deliveries in window

  Only channels whose adapter has the `:external_delivery` capability are
  checked. For a channel without deliveries in the window, the adapter's
  `health_probe/1` (when it has one) decides between healthy and degraded.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Converger.Channels.Adapter
  alias Converger.Channels.Channel
  alias Converger.Channels.HealthCheck
  alias Converger.Channels.UrlGuard
  alias Converger.Deliveries.Delivery
  alias Converger.Repo

  @healthy_threshold 0.10
  @degraded_threshold 0.50

  @doc """
  Compute health metrics for a single channel over a time window.
  Returns `{status, total, failed, rate}`.
  """
  def compute_channel_health(channel_id, window_minutes \\ 60) do
    window_start = DateTime.utc_now() |> DateTime.add(-window_minutes, :minute)

    result =
      from(d in Delivery,
        where: d.channel_id == ^channel_id and d.inserted_at > ^window_start,
        select: %{
          total: count(d.id),
          failed: count(fragment("CASE WHEN ? = 'failed' THEN 1 END", d.status))
        }
      )
      |> Repo.one()

    total = result.total
    failed = result.failed

    if total == 0 do
      {"unknown", 0, 0, 0.0}
    else
      rate = failed / total

      status =
        cond do
          rate >= @degraded_threshold -> "unhealthy"
          rate >= @healthy_threshold -> "degraded"
          true -> "healthy"
        end

      {status, total, failed, Float.round(rate, 4)}
    end
  end

  @doc """
  Run health checks for all active channels. Returns a list of
  `{channel, health_check, previous_status}` tuples where the status changed.
  """
  def check_all_channels(window_minutes \\ 60) do
    channels = list_monitored_channels()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Enum.reduce(channels, [], fn channel, changes ->
      previous = get_latest_health(channel.id)
      previous_status = if previous, do: previous.status, else: nil

      {status, total, failed, rate} =
        case compute_channel_health(channel.id, window_minutes) do
          {"unknown", total, failed, rate} -> {probe_status(channel), total, failed, rate}
          result -> result
        end

      {:ok, health_check} =
        %HealthCheck{}
        |> HealthCheck.changeset(%{
          channel_id: channel.id,
          status: status,
          total_deliveries: total,
          failed_deliveries: failed,
          failure_rate: rate,
          checked_at: now
        })
        |> Repo.insert()

      if previous_status != nil and previous_status != status do
        [{channel, health_check, previous_status} | changes]
      else
        changes
      end
    end)
  end

  @doc """
  Active channels that get health checks: those whose adapter has the
  `:external_delivery` capability, with the tenant preloaded.
  """
  def list_monitored_channels do
    types = Adapter.types_with(:external_delivery)

    from(c in Channel,
      where: c.status == "active" and c.type in ^types,
      preload: [:tenant]
    )
    |> Repo.all()
  end

  # A channel without deliveries in the window says nothing about its
  # provider. When its adapter has a health probe (and probes are enabled),
  # the probe decides: `healthy`, or `degraded` on failure. Never
  # `unhealthy`: one failed probe must not open the circuit breaker.
  defp probe_status(channel) do
    if probe_idle_channels?() do
      case Adapter.health_probe(channel) do
        :ok ->
          "healthy"

        :unsupported ->
          "unknown"

        {:error, reason} ->
          Logger.warning("Health probe failed for channel #{channel.id}: #{inspect(reason)}")
          "degraded"
      end
    else
      "unknown"
    end
  rescue
    error ->
      Logger.warning(
        "Health probe crashed for channel #{channel.id}: #{Exception.message(error)}"
      )

      "degraded"
  end

  defp probe_idle_channels? do
    :converger
    |> Application.get_env(:channel_health, [])
    |> Keyword.get(:probe_idle_channels, true)
  end

  @doc """
  Get the latest health check for a channel.
  """
  def get_latest_health(channel_id) do
    from(h in HealthCheck,
      where: h.channel_id == ^channel_id,
      order_by: [desc: h.checked_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Batch query returning `%{channel_id => %HealthCheck{}}` for the most recent
  health check of each given channel.
  """
  def get_latest_health_map(channel_ids) when is_list(channel_ids) and channel_ids != [] do
    subquery =
      from(h in HealthCheck,
        where: h.channel_id in ^channel_ids,
        select: %{channel_id: h.channel_id, max_checked_at: max(h.checked_at)},
        group_by: h.channel_id
      )

    from(h in HealthCheck,
      join: s in subquery(subquery),
      on: h.channel_id == s.channel_id and h.checked_at == s.max_checked_at
    )
    |> Repo.all()
    |> Map.new(&{&1.channel_id, &1})
  end

  def get_latest_health_map(_), do: %{}

  @doc """
  List recent health checks for a channel (for trend views).
  """
  def list_health_history(channel_id, limit \\ 50) do
    from(h in HealthCheck,
      where: h.channel_id == ^channel_id,
      order_by: [desc: h.checked_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Delete health checks older than the given number of days (default: the
  `:health_check_days` window of `Converger.Retention`), in batches. Runs
  daily from `Converger.Workers.PruneWorker`.
  """
  def prune_old_checks(days \\ Converger.Retention.health_check_days()) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day)
    count = Converger.Retention.prune_older_than("channel_health_checks", "checked_at", cutoff)

    Logger.info("Pruned #{count} old channel health checks")
    {:ok, count}
  end

  @doc """
  Send a webhook alert for a health status change.
  Fire-and-forget with 10s timeout.
  """
  def send_alert_webhook(channel, health_check, previous_status) do
    tenant = channel.tenant

    if tenant && tenant.alert_webhook_url && tenant.alert_webhook_url != "" do
      payload = %{
        event: "channel_health_changed",
        channel_id: channel.id,
        channel_name: channel.name,
        tenant_id: tenant.id,
        previous_status: previous_status,
        new_status: health_check.status,
        failure_rate: health_check.failure_rate,
        total_deliveries: health_check.total_deliveries,
        failed_deliveries: health_check.failed_deliveries,
        checked_at: DateTime.to_iso8601(health_check.checked_at)
      }

      Task.start(fn -> post_alert(channel, tenant.alert_webhook_url, payload) end)
    end
  end

  # Re-check the target at send time (DNS may have changed since the URL was
  # saved, and URLs saved before the guard existed were never checked), and
  # never follow redirects to a target that was not checked.
  defp post_alert(channel, url, payload) do
    case UrlGuard.resolve(url) do
      {:ok, _target} ->
        do_post_alert(channel, url, payload)

      {:error, reason} ->
        Logger.warning(
          "Health alert for channel #{channel.id} not sent: target rejected (" <>
            UrlGuard.format_error(reason) <> ")"
        )
    end
  end

  defp do_post_alert(channel, url, payload) do
    case Converger.HTTP.post(url, json: payload, receive_timeout: 10_000, redirect: false) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("Health alert sent for channel #{channel.id} to #{url}")

      {:ok, %{status: status}} ->
        Logger.warning("Health alert webhook returned #{status} for channel #{channel.id}")

      {:error, reason} ->
        Logger.warning(
          "Health alert webhook failed for channel #{channel.id}: #{inspect(reason)}"
        )
    end
  end

  @doc """
  Broadcast a health status change via PubSub.
  """
  def broadcast_health_change(channel, health_check, previous_status) do
    ConvergerWeb.Endpoint.broadcast!("channel_health", "health_changed", %{
      channel_id: channel.id,
      channel_name: channel.name,
      tenant_id: channel.tenant_id,
      previous_status: previous_status,
      status: health_check.status,
      failure_rate: health_check.failure_rate,
      total_deliveries: health_check.total_deliveries,
      failed_deliveries: health_check.failed_deliveries,
      checked_at: health_check.checked_at
    })
  end
end
