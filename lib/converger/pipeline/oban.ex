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
    # 1. Broadcast to WebSocket clients (inline - fast)
    Converger.Pipeline.broadcast(activity)

    # 2. Enqueue delivery to external channels (via Oban job)
    case Converger.Pipeline.resolve_delivery_channel(activity) do
      nil ->
        :ok

      channel ->
        %{activity_id: activity.id, channel_id: channel.id}
        |> Converger.Workers.ActivityDeliveryWorker.new()
        |> Oban.insert()

        Logger.debug("Delivery enqueued via Oban",
          activity_id: activity.id,
          channel_id: channel.id
        )

        :ok
    end
  end
end
