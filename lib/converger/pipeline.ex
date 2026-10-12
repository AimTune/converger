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
  alias Converger.Pipeline.{Middleware, RetryPolicy}

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
  Plan the deliveries of an activity: every candidate channel, why it is a
  candidate and, when it is left out, why.

  Candidates depend on the routing direction (`Converger.RoutingRules.route/3`):

    * `:inbound` - the conversation's origin channel (`reason: :origin`) and
      the targets of the origin channel's matching rules (`:rule`);
    * `:reply` - the activity came in on another channel: the origin channel
      (`:reply_back`, the conversation's participant is there), the replying
      channel itself when it is a `websocket` hub (`:source_hub`: its other
      sockets, such as other agents' consoles, see the reply), and the targets
      of the replying channel's matching rules (`:rule`).

  A candidate is left out (`excluded`) when its adapter cannot deliver
  (`:not_deliverable`), its mode is `inbound` (`:inbound_only`), a rule
  target is not active (`:inactive`), it would echo the participant's own
  message back to them (`:echo`), or it does not take the activity's type
  (`:unsupported_activity`).

  Options: `:conversation`, `:participant` (loaded when not given), `:rules`
  and `:at` (passed to `Converger.RoutingRules.route/3`).

  Returns `%{route: route, entries: [%{channel, reason, rule_ids, excluded}]}`.
  """
  def plan(activity, opts \\ []) do
    conversation =
      Keyword.get_lazy(opts, :conversation, fn ->
        Converger.Conversations.get_conversation!(activity.conversation_id)
      end)

    participant =
      Keyword.get_lazy(opts, :participant, fn ->
        conversation.participant_id &&
          Converger.Participants.get_participant(conversation.participant_id)
      end)

    route =
      Converger.RoutingRules.route(
        activity,
        conversation,
        Keyword.merge(Keyword.take(opts, [:rules, :at]), participant: participant)
      )

    entries =
      route
      |> candidates()
      |> Enum.map(&exclude_undeliverable/1)
      |> exclude_echo(activity, participant)
      |> Enum.map(fn
        %{excluded: nil, channel: channel} = entry ->
          if accepts_activity?(channel, activity),
            do: entry,
            else: %{entry | excluded: :unsupported_activity}

        entry ->
          entry
      end)

    %{route: route, entries: entries}
  end

  # One entry per channel, in order: the fixed ones first, then rule targets
  # in rule order. A channel named by several matched rules lists them all.
  defp candidates(route) do
    fixed =
      case route.direction do
        :inbound ->
          [{route.origin_channel_id, :origin}]

        :reply ->
          source = get_channel(route.source_channel_id)

          [{route.origin_channel_id, :reply_back}] ++
            if(source && source.type == "websocket",
              do: [{route.source_channel_id, :source_hub}],
              else: []
            )
      end

    fixed_ids = Enum.map(fixed, &elem(&1, 0))

    rule_targets =
      route.matched
      |> Enum.flat_map(fn rule -> Enum.map(rule.target_channel_ids, &{&1, rule.id}) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    ordered_targets =
      route.matched
      |> Enum.flat_map(& &1.target_channel_ids)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in fixed_ids))

    fixed_entries =
      Enum.map(fixed, fn {id, reason} ->
        %{
          channel: get_channel(id),
          channel_id: id,
          reason: reason,
          rule_ids: Map.get(rule_targets, id, []),
          excluded: nil
        }
      end)

    target_entries =
      Enum.map(ordered_targets, fn id ->
        %{
          channel: get_channel(id),
          channel_id: id,
          reason: :rule,
          rule_ids: Map.fetch!(rule_targets, id),
          excluded: nil
        }
      end)

    Enum.reject(fixed_entries ++ target_entries, &is_nil(&1.channel))
  end

  defp get_channel(nil), do: nil
  defp get_channel(id), do: Converger.Repo.get(Converger.Channels.Channel, id)

  # The conversation's own channels (origin, reply-back, source hub) are not
  # checked for `status` (a paused channel parks its jobs, ADR-0031); rule
  # targets must be active, as before conditional routing.
  defp exclude_undeliverable(%{channel: channel, reason: reason} = entry) do
    cond do
      not deliverable?(channel) -> %{entry | excluded: :not_deliverable}
      channel.mode not in ["outbound", "duplex"] -> %{entry | excluded: :inbound_only}
      reason == :rule and channel.status != "active" -> %{entry | excluded: :inactive}
      true -> entry
    end
  end

  defp exclude_echo(entries, activity, participant) do
    candidates = for %{excluded: nil, channel: channel} <- entries, do: channel
    echo_ids = participant_echo_channel_ids(activity, participant, candidates)

    Enum.map(entries, fn
      %{excluded: nil, channel: %{id: id}} = entry ->
        if id in echo_ids, do: %{entry | excluded: :echo}, else: entry

      entry ->
        entry
    end)
  end

  @doc """
  The channels that should receive a delivery for this activity: the
  entries of `plan/2` that are not excluded. Returns a list of Channel
  structs (may be empty). A channel is deliverable when its adapter has the
  `:outbound` capability (`Converger.Channels.Adapter.capabilities/1`).
  """
  def resolve_delivery_channels(activity, opts \\ []) do
    activity |> plan(opts) |> planned_channels()
  end

  defp planned_channels(%{entries: entries}) do
    for %{excluded: nil, channel: channel} <- entries, do: channel
  end

  @doc """
  The delivery channels of a stored activity (`resolve_delivery_channels/2`),
  recording in `conversation_channels` the channel it came in on and the
  channels it is delivered to. Used by the pipeline backends.
  """
  def delivery_channels(activity) do
    conversation = Converger.Conversations.get_conversation!(activity.conversation_id)
    plan = plan(activity, conversation: conversation)
    channels = planned_channels(plan)

    source = Map.get(activity, :source_channel_id)

    source_entry =
      cond do
        is_nil(source) -> []
        source == plan.route.origin_channel_id -> []
        true -> [{source, "member"}]
      end

    Converger.Conversations.record_channels(
      conversation,
      Enum.map(channels, &{&1.id, "target"}) ++ source_entry
    )

    channels
  end

  defp deliverable?(channel), do: Adapter.capability?(channel.type, :outbound)

  # A message from a participant (e.g. a WhatsApp user, an email sender) is
  # never delivered back to them on a channel where they are that
  # participant: the conversation's own participant, or a participant of a
  # target channel with the activity's sender as external id (an email reply
  # that joined a web chat conversation by its In-Reply-To, ADR-0042).
  # Returns those channel ids. A websocket channel is exempt: it is a hub of
  # many sockets (the participant's other tabs, an agent console on the same
  # channel), and the sending socket drops the frame by `seq`.
  defp participant_echo_channel_ids(activity, participant, candidates) do
    candidate_ids = for c <- candidates, c.type != "websocket", do: c.id
    sender = Map.get(activity, :sender)

    own =
      case participant do
        %{external_id: external_id, channel_id: channel_id}
        when external_id == sender and not is_nil(sender) ->
          if Converger.Channels.get_channel!(channel_id).type == "websocket",
            do: [],
            else: [channel_id]

        _ ->
          []
      end

    own ++ Converger.Participants.channels_with_participant(candidate_ids, sender)
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
  Transform an activity for delivery to `channel`: the channel's own
  middleware (`channel.transformations`), then the transformations of the
  routing rules that matched the activity and target the channel, in rule
  order (ADR-0046).

  `rules` are those matched rules; when not given they are found by routing
  the activity again (`Converger.RoutingRules.route/3`), which is skipped when
  no enabled rule targeting the channel has transformations.

  Returns `{:ok, activity}` or `{:halt, reason}`.
  """
  def transform(activity, channel, rules \\ nil) do
    with {:ok, transformed} <- Middleware.run(activity, channel) do
      rules
      |> rules_for(activity, channel)
      |> Enum.reduce_while({:ok, transformed}, fn rule, {:ok, acc} ->
        case Middleware.run(acc, %{channel | transformations: rule.transformations}) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:halt, reason} -> {:halt, {:halt, reason}}
        end
      end)
    end
  end

  defp rules_for(nil, activity, channel) do
    with tenant_id when is_binary(tenant_id) <- Map.get(activity, :tenant_id),
         conversation_id when is_binary(conversation_id) <- Map.get(activity, :conversation_id),
         true <- Converger.RoutingRules.transformations_target?(tenant_id, channel.id),
         %Converger.Conversations.Conversation{} = conversation <-
           Converger.Conversations.get_conversation(conversation_id) do
      rules_for(Converger.RoutingRules.route(activity, conversation).matched, activity, channel)
    else
      _ -> []
    end
  end

  defp rules_for(rules, _activity, channel) do
    Enum.filter(rules, &(channel.id in &1.target_channel_ids and &1.transformations != []))
  end

  @doc """
  What `channel` would be sent for `activity`, without sending it: the type
  downgrade (`Converger.Activities.Downgrade`), then `transform/3` with the
  matched `rules`. Returns `{:ok, activity}`, `{:halt, reason}` or
  `{:skip, reason}`. Used by the routing dry-run.
  """
  def preview(activity, channel, rules) do
    case Downgrade.plan(activity, channel) do
      :native -> transform(activity, channel, rules)
      {:downgrade, downgraded} -> transform(downgraded, channel, rules)
      :skip -> {:skip, "unsupported activity type #{activity.type}"}
    end
  end

  @doc """
  Execute the actual delivery via middleware + adapter + delivery tracking.

  The middleware chain (`transform/3`: the channel's `transformations`, then
  those of the routing rules that matched the activity and target the channel)
  runs before the adapter. If any middleware halts, the delivery is dead-lettered immediately.

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

    # A participant who opted out (an SMS STOP) gets nothing on this channel:
    # failed fast, without calling the provider or counting against its
    # circuit, and not retried.
    case Converger.Participants.opted_out_recipient(activity, channel.id) do
      nil ->
        plan_delivery(delivery, activity, channel)

      recipient ->
        reason = "recipient #{recipient} opted out"
        Deliveries.mark_dead(delivery, reason)
        {:error, {:halted, reason}}
    end
  end

  defp plan_delivery(delivery, activity, channel) do
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

    case transform(activity, channel) do
      {:halt, reason} ->
        Deliveries.mark_dead(delivery, "halted: #{reason}")
        {:error, {:halted, reason}}

      {:ok, transformed_activity} ->
        # Times the adapter call only (Converger.Telemetry), not the
        # bookkeeping around it. Every failure is classified by the adapter
        # (normalize_error/1) into a DeliveryError before the breaker and the
        # retry policy see it.
        {result, duration} =
          Converger.Telemetry.delivery_attempt(delivery, activity, channel, fn ->
            case Adapter.deliver_activity(channel, transformed_activity) do
              {:error, reason} -> {:error, Adapter.normalize_error(channel, reason)}
              other -> other
            end
          end)

        Converger.Channels.Circuit.record(channel, result)
        outcome = record_result(result, delivery, channel)

        Converger.Telemetry.delivery_stop(
          delivery,
          activity,
          channel,
          {result, duration},
          outcome
        )

        outcome
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
