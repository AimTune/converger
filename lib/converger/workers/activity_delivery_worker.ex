defmodule Converger.Workers.ActivityDeliveryWorker do
  # The delivery record's `attempts` counter (see Converger.Pipeline.RetryPolicy)
  # decides when to stop: once the delivery is dead-lettered the job is
  # cancelled. `max_attempts` here is only a safety cap and must be at least
  # the policy's maximum, since a job may pick up a delivery that another
  # backend (Broadway) already attempted.
  use Oban.Worker,
    queue: :deliveries,
    max_attempts: 20,
    priority: 1,
    # One live delivery job per activity/channel pair, forever. Cancelled or
    # discarded jobs are excluded (default states) so dead deliveries can be
    # re-enqueued explicitly.
    unique: [keys: [:activity_id, :channel_id], period: :infinity]

  require Logger

  alias Converger.{Activities, Channels, Pipeline}
  alias Converger.Pipeline.RetryPolicy

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"activity_id" => activity_id, "channel_id" => channel_id}}) do
    activity = Activities.get_activity!(activity_id)
    channel = Channels.get_channel!(channel_id)

    case Pipeline.deliver(activity, channel) do
      :ok ->
        Logger.info("Activity delivered",
          activity_id: activity_id,
          channel_id: channel_id,
          channel_type: channel.type
        )

        :ok

      {:error, reason} = result ->
        Logger.warning("Activity delivery failed",
          activity_id: activity_id,
          channel_id: channel_id,
          error: inspect(reason)
        )

        if Pipeline.retryable?(result), do: result, else: {:cancel, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: RetryPolicy.backoff(attempt)
end
