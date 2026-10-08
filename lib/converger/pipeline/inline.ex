defmodule Converger.Pipeline.Inline do
  @moduledoc """
  Synchronous inline pipeline backend.

  Executes broadcast and delivery synchronously in the calling process.
  No background jobs, no queuing - useful for testing and development.

  **Not durable**: deliveries run after the activity commits, so a crash in
  between loses them.

      config :converger, :pipeline,
        backend: Converger.Pipeline.Inline
  """

  @behaviour Converger.Pipeline

  require Logger

  @impl true
  def child_specs, do: []

  # Delivery performs network I/O, so it must not run inside the persistence
  # transaction. Nothing is enqueued durably: this backend is not crash-safe.
  @impl true
  def enqueue(_activity), do: :ok

  @impl true
  def after_commit(activity) do
    Converger.Pipeline.broadcast(activity)

    channels = Converger.Pipeline.resolve_delivery_channels(activity)

    Enum.each(channels, fn channel ->
      case Converger.Pipeline.deliver(activity, channel) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Inline delivery failed",
            activity_id: activity.id,
            channel_id: channel.id,
            error: inspect(reason)
          )
      end
    end)

    :ok
  end
end
