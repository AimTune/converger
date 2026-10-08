defmodule Converger.Activities do
  @moduledoc """
  The Activities context.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Converger.Repo
  alias Converger.Activities.Activity

  # Activities are ordered by their per-conversation sequence number `seq`,
  # assigned under a row lock on the conversation when the activity is
  # inserted (see create_activity/1). Unlike (inserted_at, id) this is strict,
  # gap-free and independent of node clocks.

  # Every list function here is bounded: the page size defaults to
  # `:activity_default_limit` and is capped at `:activity_max_limit`
  # (`config :converger, :pagination`, see Converger.Pagination). Callers that
  # need to know whether more activities exist use the `page_*` variants,
  # which return `{activities, has_more}`.

  @doc """
  The first page of a conversation's activities, oldest first.

  Options: `:limit` (clamped, see `Converger.Pagination.clamp_limit/2`).
  """
  def list_activities_for_conversation(conversation_id, opts \\ []) do
    conversation_id |> page_activities_since(nil, opts) |> elem(0)
  end

  @doc "Activities of a conversation with `seq` greater than `seq`, in order (one page)."
  def list_activities_after_seq(conversation_id, seq, opts \\ []) when is_integer(seq) do
    conversation_id |> page_activities_since({:seq, seq}, opts) |> elem(0)
  end

  @doc """
  Activities after the given activity (by id), in order (one page). Falls back
  to the start of the conversation when the activity is unknown. Kept for
  clients that resume by activity id (legacy WebSocket, pre-`seq` watermarks).
  """
  def list_activities_after(conversation_id, last_activity_id, opts \\ []) do
    conversation_id |> page_activities_since({:activity_id, last_activity_id}, opts) |> elem(0)
  end

  @doc """
  Activities after a decoded watermark position (see
  `Converger.ConvergerAPI.Watermark.decode/1`), one page. `nil` means from the start.
  """
  def list_activities_since(conversation_id, position, opts \\ []) do
    conversation_id |> page_activities_since(position, opts) |> elem(0)
  end

  @doc """
  One page of activities after `position` (`nil`, `{:seq, n}` or
  `{:activity_id, id}`), oldest first.

  Returns `{activities, has_more}`; when `has_more` is true, continue from the
  `seq` of the last activity returned. An unknown activity id starts from the
  beginning of the conversation.
  """
  def page_activities_since(conversation_id, position, opts \\ []) do
    limit = Converger.Pagination.clamp_limit(Keyword.get(opts, :limit), :activity)

    query =
      from(a in Activity,
        where: a.conversation_id == ^conversation_id,
        order_by: [asc: a.seq],
        limit: ^(limit + 1)
      )

    query =
      case resolve_position(conversation_id, position) do
        nil -> query
        seq -> where(query, [a], a.seq > ^seq)
      end

    query |> Repo.all() |> Converger.Pagination.split(limit)
  end

  @doc """
  The most recent page of a conversation's activities, returned oldest first
  (for transcript views that open at the latest message).

  Options: `:limit`, and `:before_seq` to load the page preceding an
  already-loaded activity. Returns `{activities, has_more}` where `has_more`
  means older activities exist.
  """
  def page_recent_activities(conversation_id, opts \\ []) do
    limit = Converger.Pagination.clamp_limit(Keyword.get(opts, :limit), :activity)

    query =
      from(a in Activity,
        where: a.conversation_id == ^conversation_id,
        order_by: [desc: a.seq],
        limit: ^(limit + 1)
      )

    query =
      case Keyword.get(opts, :before_seq) do
        seq when is_integer(seq) -> where(query, [a], a.seq < ^seq)
        _ -> query
      end

    {newest_first, has_more} = query |> Repo.all() |> Converger.Pagination.split(limit)
    {Enum.reverse(newest_first), has_more}
  end

  @doc deprecated: "Use list_activities_after/2 or list_activities_after_seq/2"
  def list_activities_after_watermark(conversation_id, watermark_activity_id) do
    list_activities_after(conversation_id, watermark_activity_id)
  end

  defp resolve_position(_conversation_id, nil), do: nil
  defp resolve_position(_conversation_id, {:seq, seq}) when is_integer(seq), do: seq
  defp resolve_position(conversation_id, {:activity_id, id}), do: seq_of(conversation_id, id)

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
  """
  def create_activity(attrs \\ %{}) do
    # 1. Optimistic fetch to avoid transaction poisoning
    case fetch_existing_activity(attrs) do
      %Activity{} = activity ->
        {:ok, activity}

      nil ->
        # 2. Persist the activity and enqueue its deliveries in one transaction
        #    (transactional outbox): either both commit or neither does.
        result =
          Repo.transaction(fn ->
            with {:ok, activity} <- insert_with_seq(attrs),
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

          {:error, :delivery_enqueue_failed} ->
            {:error, :delivery_enqueue_failed}

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
  defp insert_with_seq(attrs) do
    changeset = Activity.changeset(%Activity{}, attrs)

    with {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert) do
      conversation_id = Ecto.Changeset.get_field(changeset, :conversation_id)

      case next_seq(conversation_id) do
        {:ok, seq} ->
          changeset |> Ecto.Changeset.put_change(:seq, seq) |> Repo.insert()

        :error ->
          changeset
          |> Ecto.Changeset.add_error(:conversation_id, "does not exist")
          |> Ecto.Changeset.apply_action(:insert)
      end
    end
  end

  defp next_seq(conversation_id) do
    query =
      from(c in Converger.Conversations.Conversation,
        where: c.id == ^conversation_id,
        select: c.last_seq
      )

    case Repo.update_all(query, inc: [last_seq: 1]) do
      {1, [seq]} -> {:ok, seq}
      {0, _} -> :error
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
