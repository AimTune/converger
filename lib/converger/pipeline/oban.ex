defmodule Converger.Pipeline.Oban do
  @moduledoc """
  Oban-based pipeline backend.

  Delivery jobs are inserted inside the same database transaction as the
  activity (transactional outbox), so a committed activity always has its
  delivery jobs. Jobs are unique per `{activity_id, channel_id}`, so
  re-processing an activity never duplicates deliveries.

  PubSub broadcast is done after commit (fast, no persistence needed).

  Best for: Production use with guaranteed delivery.

      config :converger, :pipeline,
        backend: Converger.Pipeline.Oban
  """

  @behaviour Converger.Pipeline

  require Logger

  alias Converger.Workers.ActivityDeliveryWorker

  @impl true
  def child_specs, do: []

  @impl true
  def enqueue(activity) do
    activity
    |> Converger.Pipeline.resolve_delivery_channels()
    |> Enum.reduce_while(:ok, fn channel, :ok ->
      %{activity_id: activity.id, channel_id: channel.id}
      |> ActivityDeliveryWorker.new()
      |> Oban.insert()
      |> case do
        {:ok, _job} ->
          Logger.debug("Delivery enqueued via Oban",
            activity_id: activity.id,
            channel_id: channel.id
          )

          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:enqueue_failed, reason}}}
      end
    end)
  end

  @impl true
  def after_commit(activity) do
    Converger.Pipeline.broadcast(activity)
  end
end
