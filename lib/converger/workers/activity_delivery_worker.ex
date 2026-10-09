defmodule Converger.Workers.ActivityDeliveryWorker do
  # The delivery record's `attempts` counter and the channel's retry policy
  # (Converger.Pipeline.RetryPolicy.for_channel/1) decide when to stop: once
  # the delivery is dead-lettered the job is cancelled. `max_attempts` here is
  # only a safety cap above any sane per-channel `max_attempts`.
  #
  # Jobs run in the queue of the tenant's tier (Converger.Pipeline.Oban); the
  # `queue` below is only the default for jobs inserted without one.
  use Oban.Worker,
    queue: :deliveries,
    max_attempts: 100,
    priority: 1,
    # One live delivery job per activity/channel pair, forever, whatever its
    # queue. Cancelled or discarded jobs are excluded (default states) so dead
    # deliveries can be re-enqueued explicitly.
    unique: [fields: [:worker, :args], keys: [:activity_id, :channel_id], period: :infinity]

  require Logger

  alias Converger.{Activities, Channels, Pipeline}
  alias Converger.Channels.{Circuit, DeliveryError}
  alias Converger.Pipeline.RetryPolicy

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"activity_id" => activity_id, "channel_id" => channel_id}} = job) do
    channel = Channels.get_channel!(channel_id)

    # Circuit breaker, manual pause and rate limit are checked before the
    # activity is even loaded: a parked job costs a couple of cheap queries.
    case Circuit.admit(channel) do
      :ok ->
        deliver(Activities.get_activity!(activity_id), channel)

      {:park, reason} ->
        {:snooze, Circuit.park(job, channel, reason)}

      {:snooze, seconds} ->
        {:snooze, seconds}
    end
  end

  defp deliver(activity, channel) do
    case Pipeline.deliver(activity, channel) do
      :ok ->
        Logger.info("Activity delivered",
          activity_id: activity.id,
          channel_id: channel.id,
          channel_type: channel.type
        )

        :ok

      {:error, reason} = result ->
        Logger.warning("Activity delivery failed",
          activity_id: activity.id,
          channel_id: channel.id,
          error: inspect(reason)
        )

        if Pipeline.retryable?(result), do: result, else: {:cancel, reason}
    end
  end

  # A provider Retry-After (e.g. 429) wins; otherwise the channel's policy backoff.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt, args: args} = job) do
    policy =
      with id when is_binary(id) <- args["channel_id"],
           %Converger.Channels.Channel{} = channel <-
             Converger.Repo.get(Converger.Channels.Channel, id) do
        RetryPolicy.for_channel(channel)
      else
        _ -> RetryPolicy.default()
      end

    delay_ms = Pipeline.retry_delay_ms(policy, attempt, delivery_error(job))
    max(div(delay_ms, 1000), 1)
  end

  defp delivery_error(%Oban.Job{unsaved_error: %{reason: reason}}), do: unwrap(reason)
  defp delivery_error(_job), do: nil

  defp unwrap(%Oban.PerformError{reason: {:error, %DeliveryError{} = error}}), do: error
  defp unwrap(%DeliveryError{} = error), do: error
  defp unwrap(_), do: nil
end
