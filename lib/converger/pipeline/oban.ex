defmodule Converger.Pipeline.Oban do
  @moduledoc """
  Oban-based pipeline backend.

  Delivery jobs are inserted inside the same database transaction as the
  activity (transactional outbox), so a committed activity always has its
  delivery jobs. Jobs are unique per `{activity_id, channel_id}`, so
  re-processing an activity never duplicates deliveries.

  Jobs go to the queue of the tenant's tier (`tenants.tier`, see
  `queue_for_tier/1`), so bulk senders cannot starve interactive tenants.

  PubSub broadcast is done after commit (fast, no persistence needed).

  Best for: Production use with guaranteed delivery.

      config :converger, :pipeline,
        backend: Converger.Pipeline.Oban
  """

  @behaviour Converger.Pipeline

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Converger.Workers.ActivityDeliveryWorker

  # `default` keeps the historical `deliveries` queue name, so jobs enqueued
  # before tiers existed are still processed.
  @tier_queues %{"high" => :deliveries_high, "default" => :deliveries, "bulk" => :deliveries_bulk}

  @doc "Delivery queue of a tenant tier (`high`, `default`, `bulk`)."
  def queue_for_tier(tier), do: Map.get(@tier_queues, tier, :deliveries)

  @doc "Every delivery queue, highest tier first."
  def delivery_queues, do: [:deliveries_high, :deliveries, :deliveries_bulk]

  @doc "Delivery queue for a tenant id."
  def queue_for_tenant(tenant_id) do
    from(t in Converger.Tenants.Tenant, where: t.id == ^tenant_id, select: t.tier)
    |> Converger.Repo.one()
    |> queue_for_tier()
  end

  @doc "Delivery queue for a channel id (its tenant's tier)."
  def queue_for_channel(channel_id) do
    from(c in Converger.Channels.Channel,
      join: t in assoc(c, :tenant),
      where: c.id == ^channel_id,
      select: t.tier
    )
    |> Converger.Repo.one()
    |> queue_for_tier()
  end

  @impl true
  def child_specs, do: []

  @impl true
  def enqueue(activity) do
    channels = Converger.Pipeline.resolve_delivery_channels(activity)
    queue = if channels != [], do: queue_for_tenant(activity.tenant_id)

    Enum.reduce_while(channels, :ok, fn channel, :ok ->
      %{activity_id: activity.id, channel_id: channel.id}
      |> ActivityDeliveryWorker.new(queue: queue)
      |> Oban.insert()
      |> case do
        {:ok, _job} ->
          Logger.debug("Delivery enqueued via Oban (#{queue})",
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
