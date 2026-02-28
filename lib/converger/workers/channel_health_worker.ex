defmodule Converger.Workers.ChannelHealthWorker do
  @moduledoc """
  Periodic Oban worker that computes health metrics for all active channels.
  Runs every 5 minutes via cron. Detects status changes, broadcasts via PubSub,
  and sends webhook alerts to tenants with configured alert URLs.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias Converger.Channels.Health

  @impl Oban.Worker
  def perform(_job) do
    changes = Health.check_all_channels()

    Enum.each(changes, fn {channel, health_check, previous_status} ->
      Logger.info(
        "Channel health changed: #{channel.name} (#{channel.id}) " <>
          "#{previous_status} → #{health_check.status} " <>
          "(failure_rate: #{health_check.failure_rate})"
      )

      Health.broadcast_health_change(channel, health_check, previous_status)
      Health.send_alert_webhook(channel, health_check, previous_status)
    end)

    Health.prune_old_checks()

    :ok
  end
end
