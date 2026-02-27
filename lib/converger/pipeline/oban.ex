defmodule Converger.Pipeline.Oban do
  @moduledoc """
  Oban-based pipeline backend.

  Uses persistent Oban jobs for external delivery with retry and exponential backoff.
  PubSub broadcast is done inline (fast, no persistence needed).

  Best for: Production use with guaranteed delivery.

      config :converger, :pipeline,
        backend: Converger.Pipeline.Oban
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
      %{activity_id: activity.id, channel_id: channel.id}
      |> Converger.Workers.ActivityDeliveryWorker.new()
      |> Oban.insert()

      Logger.debug("Delivery enqueued via Oban",
        activity_id: activity.id,
        channel_id: channel.id
      )
    end)

    :ok
  end
end
