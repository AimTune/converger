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

  alias Converger.Activities.{Activity, Downgrade}
  alias Converger.Channels.{Adapter, DeliveryError}
  alias Converger.Pipeline.RetryPolicy

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
  @callback child_specs() :: [Supervisor.child_spec() | {module(), term()} | module()]

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

  @doc """
  Broadcast activity to WebSocket clients via PubSub.

  The payload is the full canonical activity (`Converger.Activities.Serializer`),
  so real-time clients see the same data as REST, including attachments,
  metadata and type.
  """
  def broadcast(activity) do
    ConvergerWeb.Endpoint.broadcast!(
      "conversation:#{activity.conversation_id}",
      "new_activity",
      Converger.Activities.Serializer.canonical(activity)
    )

    :ok
  end

  @doc """
  Resolve all channels that should receive a delivery for this activity.
  Returns a list of Channel structs (may be empty).
  Includes: primary channel (if deliverable) + routing rule targets (if deliverable and active).
  A channel is deliverable when its adapter has the `:outbound` capability
  (`Converger.Channels.Adapter.capabilities/1`).
  """
  def resolve_delivery_channels(activity) do
    conversation = Converger.Conversations.get_conversation!(activity.conversation_id)
    primary_channel = Converger.Channels.get_channel!(conversation.channel_id)

    primary =
      if deliverable?(primary_channel) and
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
      |> Enum.filter(&deliverable?/1)
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.filter(&(&1.mode in ["outbound", "duplex"]))

    echo_channel_id = participant_echo_channel_id(activity, conversation)

    (primary ++ additional)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&(&1.id == echo_channel_id))
    |> Enum.filter(&accepts_activity?(&1, activity))
  end

  defp deliverable?(channel), do: Adapter.capability?(channel.type, :outbound)

  # An inbound message from the conversation's participant (e.g. a WhatsApp
  # user) is never delivered back to that participant on their own channel.
  # Returns that channel's id, or nil. A websocket channel is exempt: it is a
  # hub of many sockets (the participant's other tabs, an agent console on
  # the same channel), and the sending socket drops the frame by `seq`.
  defp participant_echo_channel_id(activity, conversation) do
    case conversation.participant_id &&
           Converger.Participants.get_participant(conversation.participant_id) do
      %{external_id: external_id, channel_id: channel_id} when external_id == activity.sender ->
        if Converger.Channels.get_channel!(channel_id).type == "websocket",
          do: nil,
          else: channel_id

      _ ->
        nil
    end
  end

  # Conversation lifecycle events (close/reopen) carry no message content:
  # only adapters with the `:lifecycle_events` capability (generic webhooks,
  # WebSocket clients) receive them. Messaging adapters (WhatsApp, echo)
  # would otherwise send an empty message or reply into a closed conversation.
  #
  # Types the channel's adapter cannot deliver natively are downgraded or
  # skipped (Converger.Activities.Downgrade); skipped ones get no delivery.
  # Routing-only pseudo activities (the transient signals of
  # Converger.Channels.Signals, type "signal") are not activity types and
  # are not planned.
  defp accepts_activity?(channel, activity) do
    (not Converger.Conversations.lifecycle_event?(activity) or
       Adapter.capability?(channel.type, :lifecycle_events)) and
      (activity.type not in Activity.types() or Downgrade.plan(activity, channel) != :skip)
  end

  @doc """
  Execute the actual delivery via middleware + adapter + delivery tracking.

  The middleware chain (from `channel.transformations`) runs before the adapter.
  If any middleware halts, the delivery is dead-lettered immediately.

  Returns:

    * `:ok` - delivered (or already delivered earlier, nothing re-sent), or
      handed off to a WebSocket channel whose receipt is pending
    * `{:error, {:halted, reason}}` - halted by middleware, dead-lettered, do not retry
    * `{:error, {:dead_lettered, reason}}` - failed and out of retries, do not retry
    * `{:error, %DeliveryError{}}` - failed, retry according to
      `Converger.Pipeline.RetryPolicy`
  """
  def deliver(activity, channel) do
    alias Converger.Deliveries

    case Deliveries.get_or_create_delivery(activity, channel.id) do
      %{status: status} when status in ~w(sent delivered read) -> :ok
      delivery -> attempt_delivery(delivery, activity, channel)
    end
  end

  defp attempt_delivery(delivery, activity, channel) do
    alias Converger.Deliveries

    # Re-planned at delivery time: the channel config may have changed since
    # the delivery was enqueued.
    case Downgrade.plan(activity, channel) do
      :native ->
        run_delivery(delivery, activity, channel)

      {:downgrade, downgraded} ->
        run_delivery(delivery, downgraded, channel)

      :skip ->
        reason = "unsupported activity type #{activity.type}"
        Deliveries.mark_dead(delivery, "skipped: #{reason}")
        {:error, {:halted, reason}}
    end
  end

  defp run_delivery(delivery, activity, channel) do
    alias Converger.Deliveries
    alias Converger.Pipeline.Middleware

    case Middleware.run(activity, channel) do
      {:halt, reason} ->
        Deliveries.mark_dead(delivery, "halted: #{reason}")
        {:error, {:halted, reason}}

      {:ok, transformed_activity} ->
        # Every failure is classified by the adapter (normalize_error/1)
        # into a DeliveryError before the breaker and the retry policy see it.
        result =
          case Adapter.deliver_activity(channel, transformed_activity) do
            {:error, reason} -> {:error, Adapter.normalize_error(channel, reason)}
            other -> other
          end

        Converger.Channels.Circuit.record(channel, result)
        record_result(result, delivery, channel)
    end
  end

  defp record_result(result, delivery, channel) do
    alias Converger.Deliveries

    case result do
      :ok ->
        Deliveries.mark_sent(delivery)
        :ok

      {:ok, response_meta} ->
        Deliveries.mark_sent(delivery, response_meta)
        :ok

      # Handed off, receipt not confirmed yet (WebSocket): stays pending,
      # no retry. Deliveries.acknowledge/3 marks it sent later.
      {:pending, response_meta} ->
        Deliveries.mark_handed_off(delivery, response_meta)
        :ok

      # Permanent provider error (e.g. 400 invalid recipient): no retries.
      {:error, %DeliveryError{retryable?: false} = error} ->
        Deliveries.mark_dead(delivery, DeliveryError.message(error))
        {:error, {:dead_lettered, error}}

      {:error, %DeliveryError{} = reason} ->
        policy = RetryPolicy.for_channel(channel)

        case Deliveries.mark_attempt_failed(delivery, DeliveryError.message(reason), policy) do
          {:ok, %{status: "failed"}} -> {:error, {:dead_lettered, reason}}
          _ -> {:error, reason}
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
  def schedule_retry(%{activity_id: activity_id, channel_id: channel_id}, attempt, opts \\ []) do
    policy = RetryPolicy.for_channel(Keyword.get(opts, :channel))
    delay_ms = retry_delay_ms(policy, attempt, Keyword.get(opts, :error))

    %{activity_id: activity_id, channel_id: channel_id}
    |> Converger.Workers.ActivityDeliveryWorker.new(
      schedule_in: max(div(delay_ms, 1000), 1),
      queue: Converger.Pipeline.Oban.queue_for_channel(channel_id)
    )
    |> Oban.insert()
  end

  @doc """
  Delay before the retry following `attempt`: the provider's `Retry-After`
  when the error carries one, otherwise the policy backoff.
  """
  def retry_delay_ms(policy, attempt, error \\ nil)

  def retry_delay_ms(_policy, _attempt, %DeliveryError{retry_after_ms: ms}) when is_integer(ms),
    do: ms

  def retry_delay_ms(policy, attempt, _error), do: RetryPolicy.backoff_ms(policy, attempt)

  defp backend do
    config = Application.get_env(:converger, :pipeline, [])
    Keyword.get(config, :backend, Converger.Pipeline.Oban)
  end
end
