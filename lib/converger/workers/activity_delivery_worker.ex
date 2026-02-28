defmodule Converger.Workers.ActivityDeliveryWorker do
  use Oban.Worker,
    queue: :deliveries,
    max_attempts: 5,
    priority: 1

  require Logger

  alias Converger.{Activities, Channels}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"activity_id" => activity_id, "channel_id" => channel_id}}) do
    activity = Activities.get_activity!(activity_id)
    channel = Channels.get_channel!(channel_id)

    case Converger.Pipeline.deliver(activity, channel) do
      :ok ->
        Logger.info("Activity delivered",
          activity_id: activity_id,
          channel_id: channel_id,
          channel_type: channel.type
        )

        :ok

      {:error, reason} ->
        Logger.warning("Activity delivery failed",
          activity_id: activity_id,
          channel_id: channel_id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Exponential backoff: 10s, 30s, 90s, 270s, 810s
    trunc(:math.pow(3, attempt) * 10)
  end
end
