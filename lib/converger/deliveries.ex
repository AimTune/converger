defmodule Converger.Deliveries do
  @moduledoc """
  The Deliveries context. Tracks delivery status of activities to external channels,
  including delivery receipts and read receipts from providers.

  Status lifecycle: pending → sent → delivered → read (failed at any point).
  """

  import Ecto.Query, warn: false
  require Logger
  alias Converger.Repo
  alias Converger.Activities.Activity
  alias Converger.Deliveries.Delivery
  alias Converger.Pipeline.RetryPolicy

  @doc """
  First page of deliveries matching `filters`, newest first (bounded, see
  `paginate_deliveries/2`).
  """
  def list_deliveries(filters \\ %{}, opts \\ []) do
    {:ok, page} = paginate_deliveries(filters, Keyword.delete(opts, :cursor))
    page.entries
  end

  @doc """
  Keyset-paginated deliveries on `(inserted_at, id)`, newest first.
  Options: `:limit`, `:cursor` (see `Converger.Pagination.keyset/2`).
  """
  def paginate_deliveries(filters \\ %{}, opts \\ []) do
    Delivery
    |> apply_filters(filters)
    |> Converger.Pagination.keyset(opts)
  end

  def get_delivery!(id), do: Repo.get!(Delivery, id)

  def get_delivery_for_activity_and_channel(activity_id, channel_id) do
    Repo.get_by(Delivery, activity_id: activity_id, channel_id: channel_id)
  end

  @doc """
  The delivery of `activity` (struct or id) to `channel_id`, created when
  missing. Pass the activity struct when you have it: it saves the lookup of
  the activity's tenant and partition key.
  """
  def get_or_create_delivery(%Activity{id: activity_id} = activity, channel_id) do
    case get_delivery_for_activity_and_channel(activity_id, channel_id) do
      %Delivery{} = delivery ->
        delivery

      nil ->
        {:ok, delivery} =
          create_delivery(%{activity_id: activity_id, channel_id: channel_id}, activity)

        delivery
    end
  end

  def get_or_create_delivery(activity_id, channel_id) do
    case get_delivery_for_activity_and_channel(activity_id, channel_id) do
      %Delivery{} = delivery -> delivery
      nil -> get_or_create_delivery(Repo.get!(Activity, activity_id), channel_id)
    end
  end

  @doc """
  Creates a delivery. `tenant_id` and `activity_inserted_at` (the partition
  key) are always copied from the activity, given as `activity` or looked up
  by `attrs.activity_id`. There is no foreign key on the partitioned
  `deliveries` table (ADR-0034), so a missing activity is a changeset error.
  """
  def create_delivery(attrs, activity \\ nil) do
    changeset = Delivery.changeset(%Delivery{}, attrs)
    activity_id = Ecto.Changeset.get_field(changeset, :activity_id)

    keys =
      case activity do
        %{tenant_id: t, inserted_at: at} when not is_nil(t) and not is_nil(at) -> activity
        _ -> activity_id && activity_keys(activity_id)
      end

    case keys do
      %{tenant_id: tenant_id, inserted_at: inserted_at} ->
        changeset
        |> Ecto.Changeset.put_change(:tenant_id, tenant_id)
        |> Ecto.Changeset.put_change(:activity_inserted_at, inserted_at)
        |> Repo.insert()

      _ ->
        changeset
        |> Ecto.Changeset.add_error(:activity_id, "does not exist")
        |> Ecto.Changeset.apply_action(:insert)
    end
  end

  defp activity_keys(activity_id) do
    case Ecto.UUID.cast(activity_id) do
      {:ok, id} ->
        Repo.one(
          from(a in Activity,
            where: a.id == ^id,
            select: %{tenant_id: a.tenant_id, inserted_at: a.inserted_at}
          )
        )

      :error ->
        nil
    end
  end

  @doc """
  Mark a delivery as sent (message left our system successfully).
  Extracts provider_message_id from response metadata for future receipt
  correlation: the generic `provider_message_id` key, or the legacy
  `whatsapp_message_id` / `infobip_message_id` keys.
  """
  def mark_sent(delivery, response_metadata \\ %{}) do
    provider_msg_id = provider_message_id(response_metadata)

    attrs = %{
      status: "sent",
      sent_at: DateTime.utc_now(),
      attempts: delivery.attempts + 1,
      metadata: Map.merge(delivery.metadata || %{}, response_metadata)
    }

    attrs =
      if provider_msg_id,
        do: Map.put(attrs, :provider_message_id, to_string(provider_msg_id)),
        else: attrs

    case delivery |> Delivery.changeset(attrs) |> Repo.update() do
      {:ok, updated} = result ->
        broadcast_status_update(updated)
        result

      error ->
        error
    end
  end

  @provider_message_id_keys [
    :provider_message_id,
    "provider_message_id",
    :whatsapp_message_id,
    "whatsapp_message_id",
    :infobip_message_id,
    "infobip_message_id"
  ]

  defp provider_message_id(response_metadata),
    do: Enum.find_value(@provider_message_id_keys, &response_metadata[&1])

  @doc """
  Record a hand-off whose receipt is not confirmed yet (an adapter returned
  `{:pending, meta}`, e.g. a WebSocket channel with no connected client).
  The delivery stays `pending`; `attempts > 0` marks it as handed off, which
  is what `acknowledge/3` looks for.
  """
  def mark_handed_off(delivery, response_metadata \\ %{}) do
    delivery
    |> Delivery.changeset(%{
      status: "pending",
      attempts: delivery.attempts + 1,
      last_error: nil,
      metadata: Map.merge(delivery.metadata || %{}, response_metadata)
    })
    |> Repo.update()
  end

  @doc """
  Mark the handed-off deliveries to `channel_id` of every activity of
  `conversation_id` up to and including `seq` as `sent`: a client of the
  channel has received them (it acknowledged them or they were replayed to
  it). Deliveries not handed off yet (`attempts == 0`) are left alone, so the
  pipeline still broadcasts them to the channel's other sockets.

  Returns the number of deliveries marked.
  """
  def acknowledge(channel_id, conversation_id, seq) when is_integer(seq) do
    now = DateTime.utc_now()

    {count, deliveries} =
      from(d in Delivery,
        # The partition key lets PostgreSQL prune activities partitions (ADR-0034).
        join: a in Activity,
        on: a.id == d.activity_id and a.inserted_at == d.activity_inserted_at,
        where:
          d.channel_id == ^channel_id and d.status == "pending" and d.attempts > 0 and
            a.conversation_id == ^conversation_id and a.seq <= ^seq,
        select: d
      )
      |> Repo.update_all(set: [status: "sent", sent_at: now, updated_at: now])

    Enum.each(deliveries, &broadcast_status_update/1)
    count
  end

  @doc deprecated: "Use mark_sent/2 instead"
  def mark_delivered(delivery, response_metadata \\ %{}) do
    mark_sent(delivery, response_metadata)
  end

  @doc """
  Record a failed delivery attempt.

  The delivery stays `pending` (eligible for retry) until the attempts reach
  the policy's `max_attempts` (the channel's policy, see
  `RetryPolicy.for_channel/1`), then it is dead-lettered (`failed`).
  """
  def mark_attempt_failed(delivery, error_message, policy \\ RetryPolicy.default()) do
    new_attempts = delivery.attempts + 1

    if RetryPolicy.exhausted?(policy, new_attempts) do
      dead_letter(delivery, new_attempts, error_message)
    else
      delivery
      |> Delivery.changeset(%{
        status: "pending",
        attempts: new_attempts,
        last_error: error_message
      })
      |> Repo.update()
    end
  end

  @doc """
  Record a failed attempt that must not be retried (e.g. a middleware halt)
  and dead-letter the delivery immediately.
  """
  def mark_dead(delivery, error_message) do
    dead_letter(delivery, delivery.attempts + 1, error_message)
  end

  @doc """
  First page of dead-lettered deliveries (`status: "failed"`), most recently
  failed first. Bounded; see `paginate_dead_letters/2` for further pages.
  """
  def list_dead_letters(filters \\ %{}, opts \\ []) do
    {:ok, page} = paginate_dead_letters(filters, Keyword.delete(opts, :cursor))
    page.entries
  end

  @doc """
  Keyset-paginated dead letters on `(updated_at, id)`, most recently failed first.
  Options: `:limit`, `:cursor` (see `Converger.Pagination.keyset/2`).
  """
  def paginate_dead_letters(filters \\ %{}, opts \\ []) do
    search_deliveries(Map.put(filters, :status, "failed"), opts)
  end

  @doc """
  Keyset-paginated deliveries on `(updated_at, id)`, most recently changed
  first. Used by the dead-letter API and the admin/portal Deliveries pages.

  Filters (atom keys): `:status`, `:channel_id`, `:activity_id`,
  `:tenant_id` (through the delivery's channel), `:from` and `:to`
  (`DateTime`, inclusive bounds on `updated_at`, the time of the last status
  change, i.e. when a dead letter failed).

  Options: `:limit`, `:cursor`, `:preload` (see `Converger.Pagination.keyset/2`).
  """
  def search_deliveries(filters \\ %{}, opts \\ []) do
    Delivery
    |> apply_filters(filters)
    |> Converger.Pagination.keyset(Keyword.put(opts, :field, :updated_at))
  end

  @doc """
  Cast request params (string keys, as sent by the API, the Deliveries pages
  and the CSV export) to `search_deliveries/2` filters.

  `status` must be a delivery status, `channel_id`/`activity_id` UUIDs, and
  `from`/`to` ISO 8601 datetimes or dates (`to` as a date means the end of
  that day, UTC). Empty values are ignored.

  Returns `{:ok, filters}` or `{:error, message}`.
  """
  def cast_filters(params) when is_map(params) do
    Enum.reduce_while(~w(status channel_id activity_id from to), {:ok, %{}}, fn key, {:ok, acc} ->
      case cast_filter(key, Map.get(params, key)) do
        :skip -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, String.to_existing_atom(key), value)}}
        :error -> {:halt, {:error, "Invalid #{key}"}}
      end
    end)
  end

  defp cast_filter(_key, value) when value in [nil, ""], do: :skip

  defp cast_filter("status", value),
    do: if(value in Delivery.statuses(), do: {:ok, value}, else: :error)

  defp cast_filter(key, value) when key in ~w(channel_id activity_id) and is_binary(value),
    do: Ecto.UUID.cast(value)

  defp cast_filter(key, value) when key in ~w(from to) and is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      _ ->
        case Date.from_iso8601(value) do
          {:ok, date} when key == "from" -> DateTime.new(date, ~T[00:00:00.000000])
          {:ok, date} -> DateTime.new(date, ~T[23:59:59.999999])
          _ -> :error
        end
    end
  end

  defp cast_filter(_key, _value), do: :error

  @doc """
  The payload a delivery carries: the canonical activity
  (`Converger.Activities.Serializer`), with sensitive keys redacted
  (`Converger.Secrets.redact/1`). This is the stored activity, before the
  channel's middleware transformed its copy. `nil` when the activity is gone.
  The `:activity` association must be preloaded.
  """
  def payload_preview(%Delivery{activity: %Converger.Activities.Activity{} = activity}) do
    activity
    |> Converger.Activities.Serializer.canonical()
    |> Converger.Secrets.redact()
  end

  def payload_preview(%Delivery{}), do: nil

  @doc "A delivery by id, only if its channel belongs to `tenant_id`."
  def get_tenant_delivery(id, tenant_id) do
    from(d in Delivery,
      join: c in assoc(d, :channel),
      where: d.id == ^id and c.tenant_id == ^tenant_id
    )
    |> Repo.one()
  end

  # --- Replay (manual retry of dead letters) ---

  @bulk_retry_chunk 500

  @doc """
  Replay one dead letter.

  Atomically moves the delivery from `failed` back to `pending`, resets
  `attempts` (so the channel's retry policy starts over), increments
  `retry_count`, records `retried_by`/`retried_at`, writes a `retry` audit
  log entry and inserts an `ActivityDeliveryWorker` job, all in one
  transaction. Retries always go through Oban whatever the pipeline backend
  ("Broadway for throughput, Oban for retries", ADR-0002), so a committed
  replay always has its job.

  `actor` is `%{type: "admin" | "tenant_api" | "tenant_user" | "system", id: id}`.

  Returns `{:ok, delivery}`, `{:error, :not_failed}` when the delivery is not
  (or no longer) a dead letter, or `{:error, :channel_inactive}`.
  """
  def retry_delivery(%Delivery{} = delivery, actor) do
    delivery = Repo.preload(delivery, :channel)

    cond do
      delivery.status != "failed" ->
        {:error, :not_failed}

      delivery.channel.status != "active" ->
        {:error, :channel_inactive}

      true ->
        Repo.transaction(fn ->
          case reset_dead_letters(where(Delivery, id: ^delivery.id), actor) do
            [retried] ->
              insert_retry_audit_logs([retried], actor, %{"before" => before_retry(delivery)})
              retried

            [] ->
              Repo.rollback(:not_failed)
          end
        end)
        |> tap(fn
          {:ok, retried} -> after_retry([retried])
          _ -> :ok
        end)
    end
  end

  @doc """
  Replay every dead letter matching `filters` (same keys as
  `search_deliveries/2`; `:status` is forced to `"failed"`).

  Works in chunks of #{@bulk_retry_chunk}. Each chunk is one transaction that
  flips its rows from `failed` to `pending` with `FOR UPDATE SKIP LOCKED`,
  inserts one job and one audit entry per delivery, so concurrent bulk
  retries never pick the same delivery twice and a delivery never gets two
  live jobs. Only deliveries that were already failed when the call started
  are replayed (a replay that fails again during the call is left alone).
  Deliveries on inactive channels are skipped.

  Options: `:limit`, the maximum number of deliveries to replay (default
  `config :converger, :dead_letters, bulk_retry_limit: 10_000`).

  Returns `{:ok, %{retried: count, has_more: boolean}}`.
  """
  def retry_dead_letters(filters, actor, opts \\ []) do
    max = Keyword.get_lazy(opts, :limit, &bulk_retry_limit/0)
    started_at = DateTime.utc_now()

    filters =
      filters
      |> Map.put(:status, "failed")
      |> Map.update(:to, started_at, &earliest(&1, started_at))

    retried = retry_chunks(filters, actor, max, 0)
    {:ok, %{retried: retried, has_more: retried >= max and dead_letters_left?(filters)}}
  end

  @doc "Maximum deliveries replayed by one `retry_dead_letters/3` call."
  def bulk_retry_limit do
    :converger
    |> Application.get_env(:dead_letters, [])
    |> Keyword.get(:bulk_retry_limit, 10_000)
  end

  defp retry_chunks(_filters, _actor, max, done) when done >= max, do: done

  defp retry_chunks(filters, actor, max, done) do
    chunk = min(@bulk_retry_chunk, max - done)

    ids =
      filters
      |> retryable_dead_letters()
      |> order_by([d], asc: d.updated_at, asc: d.id)
      |> limit(^chunk)
      |> select([d], d.id)
      |> lock("FOR UPDATE SKIP LOCKED")

    # Lock and fetch the ids first, then update exactly those. A
    # `LIMIT ... SKIP LOCKED` subquery joined into the UPDATE may be
    # re-executed by the planner (nested loop), each run skipping the rows the
    # previous one locked, which updates more rows than the limit.
    {:ok, retried} =
      Repo.transaction(fn ->
        locked_ids = Repo.all(ids)

        retried =
          Delivery
          |> where([d], d.id in ^locked_ids)
          |> reset_dead_letters(actor)

        insert_retry_audit_logs(retried, actor, %{"bulk" => true})
        retried
      end)

    after_retry(retried)

    case length(retried) do
      0 -> done
      n when n < chunk -> done + n
      n -> retry_chunks(filters, actor, max, done + n)
    end
  end

  defp dead_letters_left?(filters), do: filters |> retryable_dead_letters() |> Repo.exists?()

  defp retryable_dead_letters(filters) do
    active_channel_ids =
      from(c in Converger.Channels.Channel, where: c.status == "active", select: c.id)

    Delivery
    |> apply_filters(filters)
    |> where([d], d.channel_id in subquery(active_channel_ids))
  end

  defp earliest(%DateTime{} = a, b), do: if(DateTime.compare(a, b) == :gt, do: b, else: a)
  defp earliest(_, b), do: b

  # Flips the dead letters selected by `query` to pending and enqueues their
  # jobs. Must run inside a transaction. The `status = 'failed'` guard makes
  # the flip the single point of truth: a delivery is replayed once however
  # many callers race on it.
  defp reset_dead_letters(query, actor) do
    now = DateTime.utc_now()

    {_count, retried} =
      query
      |> where([d], d.status == "failed")
      |> select([d], d)
      |> Repo.update_all(
        set: [
          status: "pending",
          attempts: 0,
          retried_by: retried_by(actor),
          retried_at: now,
          updated_at: now
        ],
        inc: [retry_count: 1]
      )

    enqueue_retries(retried)
    retried
  end

  @incomplete_job_states ~w(available scheduled executing retryable suspended)

  # One job per replayed delivery, inserted in a single `Oban.insert_all/1`.
  # The worker's unique option is not used: its default states include
  # `completed`, which would swallow the replay of a delivery that was sent
  # and then failed by a provider receipt, and per-job unique inserts are too
  # slow for bulk replays. Only a still-running job for the same pair is a
  # duplicate, so those pairs are looked up once and skipped. The flipped
  # rows stay locked until commit, so no other replay can race on them.
  defp enqueue_retries([]), do: :ok

  defp enqueue_retries(deliveries) do
    worker = inspect(Converger.Workers.ActivityDeliveryWorker)
    activity_ids = Enum.map(deliveries, & &1.activity_id)

    running =
      from(j in Oban.Job,
        where: j.worker == ^worker and j.state in @incomplete_job_states,
        where: fragment("?->>'activity_id' = ANY(?)", j.args, ^activity_ids),
        select: {fragment("?->>'activity_id'", j.args), fragment("?->>'channel_id'", j.args)}
      )
      |> Repo.all()
      |> MapSet.new()

    # Replays run in the queue of the tenant's tier, like first attempts.
    queues =
      deliveries
      |> Enum.map(& &1.channel_id)
      |> Enum.uniq()
      |> Map.new(&{&1, Converger.Pipeline.Oban.queue_for_channel(&1)})

    jobs =
      for %{activity_id: activity_id, channel_id: channel_id} <- deliveries,
          not MapSet.member?(running, {activity_id, channel_id}) do
        Converger.Workers.ActivityDeliveryWorker.new(
          %{activity_id: activity_id, channel_id: channel_id},
          queue: Map.fetch!(queues, channel_id)
        )
      end

    Oban.insert_all(jobs)
    :ok
  end

  defp insert_retry_audit_logs([], _actor, _changes), do: :ok

  defp insert_retry_audit_logs(deliveries, actor, changes) do
    channel_ids = deliveries |> Enum.map(& &1.channel_id) |> Enum.uniq()

    tenants =
      from(c in Converger.Channels.Channel,
        where: c.id in ^channel_ids,
        select: {c.id, c.tenant_id}
      )
      |> Repo.all()
      |> Map.new()

    now = DateTime.utc_now()

    entries =
      Enum.map(deliveries, fn delivery ->
        %{
          id: Ecto.UUID.generate(),
          tenant_id: Map.get(tenants, delivery.channel_id),
          actor_type: actor.type,
          actor_id: to_string(actor.id),
          action: "retry",
          resource_type: "delivery",
          resource_id: delivery.id,
          changes:
            Map.merge(changes, %{
              "activity_id" => delivery.activity_id,
              "channel_id" => delivery.channel_id,
              "retry_count" => delivery.retry_count
            }),
          inserted_at: now
        }
      end)

    Repo.insert_all(Converger.AuditLogs.AuditLog, entries)
    :ok
  end

  defp before_retry(delivery) do
    %{
      "status" => delivery.status,
      "attempts" => delivery.attempts,
      "last_error" => delivery.last_error
    }
  end

  defp after_retry([]), do: :ok

  defp after_retry(deliveries) do
    :telemetry.execute([:converger, :deliveries, :retried], %{count: length(deliveries)}, %{
      delivery_ids: Enum.map(deliveries, & &1.id)
    })

    deliveries
    |> Repo.preload(:activity)
    |> Enum.each(&broadcast_status_update/1)
  end

  defp retried_by(%{type: type, id: id}), do: "#{type}:#{id}"

  defp dead_letter(delivery, attempts, error_message) do
    result =
      delivery
      |> Delivery.changeset(%{status: "failed", attempts: attempts, last_error: error_message})
      |> Repo.update()

    with {:ok, dead} <- result do
      :telemetry.execute([:converger, :deliveries, :dead_lettered], %{attempts: attempts}, %{
        delivery_id: dead.id,
        activity_id: dead.activity_id,
        channel_id: dead.channel_id,
        error: error_message
      })

      Logger.warning("Delivery dead-lettered",
        delivery_id: dead.id,
        activity_id: dead.activity_id,
        channel_id: dead.channel_id,
        attempts: attempts
      )

      broadcast_status_update(dead)
    end

    result
  end

  # --- Receipt / Status Update Processing ---

  @doc """
  Apply a status update from an external provider.
  Looks up the delivery by provider_message_id or delivery_id, then
  advances the status monotonically.
  """
  def apply_status_update(channel_id, %{"provider_message_id" => pmid} = update)
      when is_binary(pmid) and pmid != "" do
    case get_delivery_by_provider_message_id(channel_id, pmid) do
      %Delivery{} = delivery -> advance_status(delivery, update)
      nil -> {:error, :delivery_not_found}
    end
  end

  # Scoped to the reporting channel, like provider_message_id lookups: a
  # signed status webhook of one channel must not be able to change the
  # status of another channel's (or tenant's) delivery by guessing its id.
  def apply_status_update(channel_id, %{"delivery_id" => delivery_id} = update)
      when is_binary(delivery_id) and delivery_id != "" do
    with {:ok, id} <- Ecto.UUID.cast(delivery_id),
         %Delivery{} = delivery <- Repo.get_by(Delivery, id: id, channel_id: channel_id) do
      advance_status(delivery, update)
    else
      _ -> {:error, :delivery_not_found}
    end
  end

  def apply_status_update(_channel_id, _update), do: {:error, :missing_identifier}

  @doc """
  Find a delivery by its provider message ID, scoped to a channel.
  """
  def get_delivery_by_provider_message_id(channel_id, provider_message_id) do
    Repo.get_by(Delivery,
      channel_id: channel_id,
      provider_message_id: provider_message_id
    )
  end

  @doc """
  Advance a delivery's status following monotonic progression rules.
  Ignores stale updates (e.g., "delivered" arriving after "read").
  Broadcasts the update via PubSub.
  """
  def advance_status(delivery, update) do
    new_status = update["status"]
    current_rank = Delivery.status_rank(delivery.status)
    new_rank = Delivery.status_rank(new_status)

    should_update =
      cond do
        new_status == "failed" and delivery.status not in ["read"] -> true
        new_rank > current_rank and current_rank >= 0 -> true
        true -> false
      end

    if should_update do
      timestamp = parse_provider_timestamp(update["timestamp"])

      attrs =
        %{status: new_status}
        |> maybe_put(:sent_at, new_status == "sent", timestamp)
        |> maybe_put(:delivered_at, new_status == "delivered", timestamp)
        |> maybe_put(:read_at, new_status == "read", timestamp)
        |> maybe_put(:last_error, new_status == "failed", update["error"])

      case delivery |> Delivery.changeset(attrs) |> Repo.update() do
        {:ok, updated} = result ->
          broadcast_status_update(updated)
          result

        error ->
          error
      end
    else
      {:ok, delivery}
    end
  end

  # --- Query Helpers ---

  @doc """
  List deliveries for a set of activity IDs (batch query for conversation show page).
  """
  def list_deliveries_for_activities(activity_ids) when is_list(activity_ids) do
    from(d in Delivery,
      where: d.activity_id in ^activity_ids,
      order_by: [desc: d.updated_at]
    )
    |> Repo.all()
  end

  def list_deliveries_for_activities(_), do: []

  def count_by_status do
    from(d in Delivery,
      group_by: d.status,
      select: {d.status, count(d.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # --- Private Helpers ---

  defp broadcast_status_update(delivery) do
    delivery = Repo.preload(delivery, :activity)

    if delivery.activity do
      ConvergerWeb.Endpoint.broadcast!(
        "conversation:#{delivery.activity.conversation_id}",
        "delivery_status",
        %{
          delivery_id: delivery.id,
          activity_id: delivery.activity_id,
          channel_id: delivery.channel_id,
          status: delivery.status,
          sent_at: delivery.sent_at,
          delivered_at: delivery.delivered_at,
          read_at: delivery.read_at,
          # For the WebSocket deliveryStatus frame (ConvergerWeb.ConvergerFrames).
          seq: delivery.activity.seq,
          sender: delivery.activity.sender,
          attempts: delivery.attempts,
          last_error: delivery.last_error,
          updated_at: delivery.updated_at
        }
      )
    end
  end

  defp parse_provider_timestamp(nil), do: DateTime.utc_now()

  defp parse_provider_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        dt

      _ ->
        case Integer.parse(ts) do
          {unix, _} -> DateTime.from_unix!(unix)
          :error -> DateTime.utc_now()
        end
    end
  end

  defp parse_provider_timestamp(ts) when is_integer(ts), do: DateTime.from_unix!(ts)
  defp parse_provider_timestamp(_), do: DateTime.utc_now()

  defp maybe_put(map, _key, false, _val), do: map
  defp maybe_put(map, key, true, val), do: Map.put(map, key, val)

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:status, value}, q when is_binary(value) ->
        where(q, status: ^value)

      {:channel_id, value}, q when is_binary(value) ->
        where(q, channel_id: ^value)

      {:activity_id, value}, q when is_binary(value) ->
        where(q, activity_id: ^value)

      {:tenant_id, value}, q when is_binary(value) ->
        where(q, [d], d.channel_id in subquery(tenant_channel_ids(value)))

      {:from, %DateTime{} = from}, q ->
        where(q, [d], d.updated_at >= ^from)

      {:to, %DateTime{} = to}, q ->
        where(q, [d], d.updated_at <= ^to)

      _, q ->
        q
    end)
  end

  defp tenant_channel_ids(tenant_id) do
    from(c in Converger.Channels.Channel, where: c.tenant_id == ^tenant_id, select: c.id)
  end
end
