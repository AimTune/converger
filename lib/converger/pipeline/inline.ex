defmodule Converger.Pipeline.Inline do
  @moduledoc """
  Synchronous inline pipeline backend.

  Executes broadcast and delivery synchronously in the calling process.
  No background jobs, no queuing - useful for testing and development.

      config :converger, :pipeline,
        backend: Converger.Pipeline.Inline
  """

  @behaviour Converger.Pipeline

  require Logger

  @impl true
  def child_specs, do: []

  @impl true
  def process(activity) do
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
