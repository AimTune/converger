defmodule Converger.Activities do
  @moduledoc """
  The Activities context.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Converger.Repo
  alias Converger.Activities.Activity
  alias Converger.Conversations
  alias Converger.Conversations.Conversation

  # Activities are ordered by their per-conversation sequence number `seq`,
  # assigned under a row lock on the conversation when the activity is
  # inserted (see create_activity/1). Unlike (inserted_at, id) this is strict,
  # gap-free and independent of node clocks.

  def list_activities_for_conversation(conversation_id) do
    from(a in Activity,
      where: a.conversation_id == ^conversation_id,
      order_by: [asc: a.seq]
    )
    |> Repo.all()
  end

  @doc "Activities of a conversation with `seq` greater than `seq`, in order."
  def list_activities_after_seq(conversation_id, seq) when is_integer(seq) do
    from(a in Activity,
      where: a.conversation_id == ^conversation_id and a.seq > ^seq,
      order_by: [asc: a.seq]
    )
    |> Repo.all()
  end

  @doc """
  Activities after the given activity (by id), in order. Falls back to the
  whole conversation when the activity is unknown. Kept for clients that
  resume by activity id (legacy WebSocket, pre-`seq` watermarks).
  """
  def list_activities_after(conversation_id, last_activity_id) do
    case seq_of(conversation_id, last_activity_id) do
      nil -> list_activities_for_conversation(conversation_id)
      seq -> list_activities_after_seq(conversation_id, seq)
    end
  end

  @doc """
  Activities after a decoded watermark position (see
  `Converger.ConvergerAPI.Watermark.decode/1`). `nil` means from the start.
  """
  def list_activities_since(conversation_id, nil),
    do: list_activities_for_conversation(conversation_id)

  def list_activities_since(conversation_id, {:seq, seq}),
    do: list_activities_after_seq(conversation_id, seq)

  def list_activities_since(conversation_id, {:activity_id, id}),
    do: list_activities_after(conversation_id, id)

  @doc deprecated: "Use list_activities_after/2 or list_activities_after_seq/2"
  def list_activities_after_watermark(conversation_id, watermark_activity_id) do
    list_activities_after(conversation_id, watermark_activity_id)
  end

  defp seq_of(conversation_id, activity_id) do
    case Ecto.UUID.cast(activity_id) do
      {:ok, id} ->
        Repo.one(
          from(a in Activity,
            where: a.id == ^id and a.conversation_id == ^conversation_id,
            select: a.seq
          )
        )

      :error ->
        nil
    end
  end

  def get_activity!(id), do: Repo.get!(Activity, id)

  @doc """
  Create an activity from untrusted client input.

  Only `Activity.client_fields/0` are taken from `client_params` (REST body,
  WebSocket payload, parsed inbound webhook); everything else, such as
  `inserted_at` or `idempotency_key`, is ignored. Server-controlled fields
  (`tenant_id`, `conversation_id`, `sender`, `idempotency_key`) come from
  `system_attrs` only.
  """
  def create_client_activity(client_params, system_attrs) when is_map(client_params) do
    client_keys = Enum.map(Activity.client_fields(), &Atom.to_string/1)

    client_params
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.take(client_keys)
    |> Map.merge(Map.new(system_attrs, fn {k, v} -> {to_string(k), v} end))
    |> create_activity()
  end

  @doc """
  Create an activity from trusted, server-built attributes. Use
  `create_client_activity/2` for anything that originates from a client.

  Activities are only accepted while the conversation is open (see
  `Converger.Conversations.open?/1`); otherwise this returns
  `{:error, :conversation_closed}`. The status check happens in the same
  statement that allocates the activity's `seq`, under the conversation row
  lock, so it is consistent with a concurrent close: an activity is either
  committed before the close or rejected.

  ## Options

    * `:allow_closed` - accept the activity even when the conversation is
      closed. Reserved for server-generated lifecycle events (the
      `conversationUpdate` emitted when a conversation is closed).
  """
  def create_activity(attrs \\ %{}, opts \\ []) do
    # 1. Optimistic fetch to avoid transaction poisoning
    case fetch_existing_activity(attrs) do
      %Activity{} = activity ->
        {:ok, activity}

      nil ->
        # 2. Persist the activity and enqueue its deliveries in one transaction
        #    (transactional outbox): either both commit or neither does.
        result =
          Repo.transaction(fn ->
            with {:ok, activity} <- insert_with_seq(attrs, opts),
                 :ok <- enqueue_deliveries(activity) do
              activity
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        case result do
          {:ok, activity} ->
            :telemetry.execute([:converger, :activities, :create], %{count: 1}, %{
              tenant_id: activity.tenant_id
            })

            # 3. Non-durable work (PubSub broadcast etc.) AFTER successful commit
            Converger.Pipeline.after_commit(activity)
            {:ok, activity}

          {:error, reason} when reason in [:delivery_enqueue_failed, :conversation_closed] ->
            {:error, reason}

          {:error, changeset} ->
            if has_idempotency_error?(changeset) do
              case fetch_existing_activity(attrs) do
                %Activity{} = activity -> {:ok, activity}
                nil -> {:error, changeset}
              end
            else
              {:error, changeset}
            end
        end
    end
  end

  # Must run inside the create transaction. Incrementing the conversation's
  # last_seq takes a row lock that is held until commit, so concurrent inserts
  # into one conversation (on any node) are numbered strictly 1, 2, 3, ...;
  # a rollback also rolls back the increment, so there are no gaps.
  # The same statement enforces the conversation status (a concurrent close
  # either commits first and rejects this insert, or waits for it) and bumps
  # `updated_at`, which the expiration worker treats as "last activity".
  defp insert_with_seq(attrs, opts) do
    changeset = Activity.changeset(%Activity{}, attrs)

    with {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert) do
      conversation_id = Ecto.Changeset.get_field(changeset, :conversation_id)

      case next_seq(conversation_id, Keyword.get(opts, :allow_closed, false)) do
        {:ok, seq} ->
          changeset |> Ecto.Changeset.put_change(:seq, seq) |> Repo.insert()

        {:error, :conversation_closed} ->
          {:error, :conversation_closed}

        :error ->
          changeset
          |> Ecto.Changeset.add_error(:conversation_id, "does not exist")
          |> Ecto.Changeset.apply_action(:insert)
      end
    end
  end

  defp next_seq(conversation_id, allow_closed?) do
    query =
      from(c in Conversation,
        where: c.id == ^conversation_id,
        select: c.last_seq
      )

    query =
      if allow_closed?,
        do: query,
        else: where(query, [c], c.status == ^Conversations.open_status())

    case Repo.update_all(query, inc: [last_seq: 1], set: [updated_at: DateTime.utc_now()]) do
      {1, [seq]} ->
        {:ok, seq}

      {0, _} ->
        if Repo.exists?(from(c in Conversation, where: c.id == ^conversation_id)),
          do: {:error, :conversation_closed},
          else: :error
    end
  end

  defp enqueue_deliveries(activity) do
    case Converger.Pipeline.enqueue(activity) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Delivery enqueue failed, rolling back activity",
          conversation_id: activity.conversation_id,
          error: inspect(reason)
        )

        {:error, :delivery_enqueue_failed}
    end
  end

  defp has_idempotency_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, {msg, _}} ->
      (field == :idempotency_key or field == :conversation_id) and msg == "has already been taken"
    end)
  end

  defp fetch_existing_activity(attrs) do
    conversation_id = attrs["conversation_id"] || attrs[:conversation_id]
    idempotency_key = attrs["idempotency_key"] || attrs[:idempotency_key]

    if conversation_id && idempotency_key do
      Repo.get_by(Activity, conversation_id: conversation_id, idempotency_key: idempotency_key)
    else
      nil
    end
  end

  def update_activity(%Activity{} = activity, attrs) do
    activity
    |> Activity.changeset(attrs)
    |> Repo.update()
  end

  def delete_activity(%Activity{} = activity) do
    Repo.delete(activity)
  end

  def change_activity(%Activity{} = activity, attrs \\ %{}) do
    Activity.changeset(activity, attrs)
  end
end
