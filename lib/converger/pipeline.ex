defmodule Converger.Pipeline do
  @moduledoc """
  Parametric activity processing pipeline.

  After an activity is persisted, it flows through the pipeline for:
  1. Broadcasting to WebSocket clients (PubSub)
  2. Delivering to external channels (webhook, WhatsApp, etc.)

  The pipeline backend is configurable:

      config :converger, :pipeline,
        backend: Converger.Pipeline.Oban      # default - durable job queue
        # backend: Converger.Pipeline.Broadway  # stream processing, not durable
        # backend: Converger.Pipeline.Inline    # synchronous (testing/dev), not durable

  ## Durability

  Every backend is driven in two phases:

    * `c:enqueue/1` runs **inside** the database transaction that persists the
      activity. Whatever it writes commits or rolls back together with the
      activity, so a crash cannot leave an activity without its deliveries.
    * `c:after_commit/1` runs once the transaction has committed. It handles
      fire-and-forget work such as the PubSub broadcast.

  | Backend                       | Delivery enqueue          | Durable |
  | ----------------------------- | ------------------------- | ------- |
  | `Converger.Pipeline.Oban`     | Oban jobs, in transaction | yes     |
  | `Converger.Pipeline.Broadway` | pushed after commit       | no      |
  | `Converger.Pipeline.Inline`   | delivered after commit    | no      |

  Only the Oban backend guarantees that every committed activity has its
  delivery jobs. Broadway pushes to its producer after commit, so a crash in
  between loses the delivery. The `:memory` producer also keeps messages in
  process memory and refuses to start in production (see
  `Converger.Pipeline.Broadway`).
  """

  @type activity :: Converger.Activities.Activity.t()

  @doc """
  Enqueue external deliveries for a freshly inserted activity.

  Called inside the persistence transaction. Returning `{:error, reason}`
  (or raising) rolls back the activity insert.
  """
  @callback enqueue(activity) :: :ok | {:error, term()}

  @doc """
  Called after the persistence transaction has committed. Handles the PubSub
  broadcast and any non-transactional delivery work.
  """
  @callback after_commit(activity) :: :ok

  @doc """
  Called on application start. Backends that need supervision (GenStage)
  return child specs. Others return an empty list.
  """
  @callback child_specs() :: [Supervisor.child_spec()]

  @doc """
  Run the in-transaction phase of the configured backend.

  Must be called inside `Converger.Repo.transaction/1`.
  """
  def enqueue(activity) do
    backend().enqueue(activity)
  end

  @doc "Run the post-commit phase of the configured backend."
  def after_commit(activity) do
    backend().after_commit(activity)
  end

  @doc """
  (Re-)process an already persisted activity through the pipeline.

  Runs `enqueue/1` in its own transaction, then `after_commit/1`. Safe to call
  repeatedly: the Oban backend uses unique jobs, so re-processing does not
  create duplicate deliveries.
  """
  def process(activity) do
    result =
      Converger.Repo.transaction(fn ->
        case enqueue(activity) do
          :ok -> :ok
          {:error, reason} -> Converger.Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> after_commit(activity)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Get child specs for the configured backend's supervision tree."
  def child_specs do
    backend().child_specs()
  end

  @doc "Broadcast activity to WebSocket clients via PubSub."
  def broadcast(activity) do
    ConvergerWeb.Endpoint.broadcast!(
      "conversation:#{activity.conversation_id}",
      "new_activity",
      %{
        id: activity.id,
        text: activity.text,
        sender: activity.sender,
        inserted_at: activity.inserted_at
      }
    )

    :ok
  end

  # Channel types delivered through an adapter. `websocket` is excluded: its
  # clients are reached by the PubSub broadcast.
  @delivery_types ~w(echo webhook whatsapp_meta whatsapp_infobip)

  @doc """
  Resolve all channels that should receive a delivery for this activity.
  Returns a list of Channel structs (may be empty).
  Includes: primary channel (if deliverable) + routing rule targets (if deliverable and active).
  """
  def resolve_delivery_channels(activity) do
    conversation = Converger.Conversations.get_conversation!(activity.conversation_id)
    primary_channel = Converger.Channels.get_channel!(conversation.channel_id)

    primary =
      if primary_channel.type in @delivery_types and
           primary_channel.mode in ["outbound", "duplex"],
         do: [primary_channel],
         else: []

    target_ids =
      Converger.RoutingRules.resolve_target_channels(
        primary_channel.id,
        conversation.tenant_id
      )

    additional_ids = target_ids -- [primary_channel.id]

    additional =
      additional_ids
      |> Enum.map(fn id ->
        try do
          Converger.Channels.get_channel!(id)
        rescue
          Ecto.NoResultsError -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1.type in @delivery_types))
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.filter(&(&1.mode in ["outbound", "duplex"]))

    (primary ++ additional) |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Execute the actual delivery via middleware + adapter + delivery tracking.

  The middleware chain (from `channel.transformations`) runs before the adapter.
  If any middleware halts, the delivery is dead-lettered immediately.

  Returns:

    * `:ok` - delivered (or already delivered earlier, nothing re-sent)
    * `{:error, {:halted, reason}}` - halted by middleware, dead-lettered, do not retry
    * `{:error, {:dead_lettered, reason}}` - failed and out of retries, do not retry
    * `{:error, reason}` - failed, retry according to `Converger.Pipeline.RetryPolicy`
  """
  def deliver(activity, channel) do
    alias Converger.Deliveries

    case Deliveries.get_or_create_delivery(activity.id, channel.id) do
      %{status: status} when status in ~w(sent delivered read) -> :ok
      delivery -> attempt_delivery(delivery, activity, channel)
    end
  end

  defp attempt_delivery(delivery, activity, channel) do
    alias Converger.{Deliveries, Channels.Adapter}
    alias Converger.Pipeline.Middleware

    case Middleware.run(activity, channel) do
      {:halt, reason} ->
        Deliveries.mark_dead(delivery, "halted: #{reason}")
        {:error, {:halted, reason}}

      {:ok, transformed_activity} ->
        case Adapter.deliver_activity(channel, transformed_activity) do
          :ok ->
            Deliveries.mark_sent(delivery)
            :ok

          {:ok, response_meta} ->
            Deliveries.mark_sent(delivery, response_meta)
            :ok

          {:error, reason} ->
            case Deliveries.mark_attempt_failed(delivery, inspect(reason)) do
              {:ok, %{status: "failed"}} -> {:error, {:dead_lettered, reason}}
              _ -> {:error, reason}
            end
        end
    end
  end

  @doc """
  Whether a `deliver/2` result is a transient failure that should be retried.
  """
  def retryable?({:error, {:halted, _}}), do: false
  def retryable?({:error, {:dead_lettered, _}}), do: false
  def retryable?({:error, _}), do: true
  def retryable?(_), do: false

  @doc """
  Schedule a durable retry for a delivery that just failed its `attempt`-th
  attempt, honouring `Converger.Pipeline.RetryPolicy` backoff.

  Used by non-Oban backends: "Broadway for throughput, Oban for retries".
  """
  def schedule_retry(%{activity_id: activity_id, channel_id: channel_id}, attempt) do
    %{activity_id: activity_id, channel_id: channel_id}
    |> Converger.Workers.ActivityDeliveryWorker.new(
      schedule_in: Converger.Pipeline.RetryPolicy.backoff(attempt)
    )
    |> Oban.insert()
  end

  defp backend do
    config = Application.get_env(:converger, :pipeline, [])
    Keyword.get(config, :backend, Converger.Pipeline.Oban)
  end
end
