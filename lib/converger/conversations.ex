defmodule Converger.Conversations do
  @moduledoc """
  The Conversations context.

  ## Lifecycle

  A conversation is either `"active"` (open) or `"closed"`.

    * Only open conversations accept activities. `Converger.Activities.create_activity/2`
      enforces this atomically and returns `{:error, :conversation_closed}`
      (REST `409`, WebSocket error reply `conversation_closed`).
    * `close_conversation/2` and `reopen_conversation/2` change the status and
      emit a `conversationUpdate` activity (sender `"system"`) so that
      connected clients are notified in-band.
    * `expire_inactive_conversations/1` (run hourly by
      `Converger.Workers.ConversationExpirationWorker`) closes open
      conversations whose `updated_at` is older than the inactivity window.
      `updated_at` is bumped whenever an activity is added, so it is the
      conversation's last-activity time.

  Use `open?/1` / `ensure_open/1` to check the rules before doing expensive
  work (e.g. uploads, or deciding whether an inbound message should start a
  new conversation instead).
  """

  import Ecto.Query, warn: false
  require Logger
  alias Converger.Repo
  alias Converger.Conversations.Conversation

  @open "active"
  @closed "closed"
  @default_inactivity_hours 24
  @expire_batch_size 500

  @doc "Status of an open conversation (one that accepts activities)."
  def open_status, do: @open

  @doc "Status of a closed conversation."
  def closed_status, do: @closed

  @doc "Whether the conversation accepts new activities."
  def open?(%Conversation{status: @open}), do: true
  def open?(%Conversation{}), do: false

  @doc "`:ok` if the conversation is open, `{:error, :conversation_closed}` otherwise."
  def ensure_open(%Conversation{} = conversation) do
    if open?(conversation), do: :ok, else: {:error, :conversation_closed}
  end

  @doc """
  Inactivity window (hours) after which open conversations are closed.
  Configure with `config :converger, :conversation_inactivity_hours, 24`.
  """
  def inactivity_hours do
    Application.get_env(:converger, :conversation_inactivity_hours, @default_inactivity_hours)
  end

  @doc """
  First page of conversations matching `filters`, newest first.

  Bounded by the configured page size; use `paginate_conversations/2` to get
  the cursor for further pages. Options: `:limit`, `:direction`, `:preload`.
  """
  def list_conversations(filters \\ %{}, opts \\ []) do
    {:ok, page} = paginate_conversations(filters, Keyword.delete(opts, :cursor))
    page.entries
  end

  def list_conversations_for_tenant(tenant_id, opts \\ []) do
    list_conversations(%{"tenant_id" => tenant_id}, opts)
  end

  @doc """
  Keyset-paginated conversations on `(inserted_at, id)`, newest first by default.

  Filters (string or atom keys, `""` ignored): `tenant_id`, `channel_id`,
  `status`, `external_id` (the participant's provider id), and `q` (a
  conversation id; anything that is not a UUID matches nothing). Options: `:limit`, `:cursor`, `:direction` (`:desc` | `:asc`),
  `:preload`. See `Converger.Pagination.keyset/2`.

  Returns `{:ok, %Converger.Pagination.Page{}}` or `{:error, :invalid_cursor}`.
  """
  def paginate_conversations(filters \\ %{}, opts \\ []) do
    Conversation
    |> apply_filters(filters)
    |> Converger.Pagination.keyset(opts)
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {key, value}, q when key in ["q", :q] and is_binary(value) and value != "" ->
        case Ecto.UUID.cast(String.trim(value)) do
          {:ok, id} -> where(q, id: ^id)
          :error -> where(q, [c], false)
        end

      {"tenant_id", value}, q when value != "" ->
        where(q, tenant_id: ^value)

      {:tenant_id, value}, q when value != "" ->
        where(q, tenant_id: ^value)

      {"channel_id", value}, q when value != "" ->
        where(q, channel_id: ^value)

      {:channel_id, value}, q when value != "" ->
        where(q, channel_id: ^value)

      {"status", value}, q when value != "" ->
        where(q, status: ^value)

      {:status, value}, q when value != "" ->
        where(q, status: ^value)

      {"external_id", value}, q when is_binary(value) ->
        where_external_id(q, value)

      {:external_id, value}, q when is_binary(value) ->
        where_external_id(q, value)

      {_, _}, q ->
        q
    end)
  end

  # Conversations whose participant (on the conversation's channel) has this
  # external id, e.g. a WhatsApp phone number.
  defp where_external_id(query, external_id) do
    from(c in query,
      join: p in assoc(c, :participant),
      where: p.external_id == ^external_id and p.channel_id == c.channel_id
    )
  end

  def get_conversation(id), do: Repo.get(Conversation, id)

  def get_conversation(id, tenant_id) do
    Repo.get_by(Conversation, id: id, tenant_id: tenant_id)
  end

  def get_conversation!(id), do: Repo.get!(Conversation, id)

  def get_conversation!(id, tenant_id) do
    Repo.get_by!(Conversation, id: id, tenant_id: tenant_id)
  end

  def create_conversation(attrs \\ %{}) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  def update_conversation(%Conversation{} = conversation, attrs) do
    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Close a conversation. Idempotent: closing a closed conversation returns it
  unchanged and emits nothing.

  The status change takes the conversation row lock, so it serialises with
  activity inserts: activities committed before the close are kept, later
  ones are rejected with `:conversation_closed`. The emitted
  `conversationUpdate` activity is therefore the last one in the conversation.

  Options: `:reason` (string, default `"manual"`), stored in the event's metadata.
  """
  def close_conversation(%Conversation{} = conversation, opts \\ []) do
    transition(conversation, @open, @closed, opts)
  end

  @doc """
  Reopen a closed conversation so it accepts activities again. Idempotent.
  Options: `:reason` (string, default `"manual"`).
  """
  def reopen_conversation(%Conversation{} = conversation, opts \\ []) do
    transition(conversation, @closed, @open, opts)
  end

  defp transition(%Conversation{id: id}, from, to, opts) do
    query = from(c in Conversation, where: c.id == ^id and c.status == ^from, select: c)

    case Repo.update_all(query, set: [status: to, updated_at: DateTime.utc_now()]) do
      {1, [conversation]} ->
        emit_lifecycle_event(conversation, Keyword.get(opts, :reason, "manual"))
        {:ok, conversation}

      {0, _} ->
        case get_conversation(id) do
          nil -> {:error, :not_found}
          %Conversation{} = conversation -> {:ok, conversation}
        end
    end
  end

  @doc """
  Open conversations with no activity (no `updated_at` change) since `threshold`.
  Served by the `(status, updated_at)` index.
  """
  def inactive_conversations_query(%DateTime{} = threshold) do
    from(c in Conversation, where: c.status == ^@open and c.updated_at < ^threshold)
  end

  @doc """
  Close every open conversation that has been inactive for longer than the
  inactivity window and emit a `conversationUpdate` for each.

  Options: `:inactivity_hours` (defaults to `inactivity_hours/0`).
  Returns `{:ok, count}`.
  """
  def expire_inactive_conversations(opts \\ []) do
    hours = Keyword.get(opts, :inactivity_hours, inactivity_hours())
    threshold = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    {:ok, expire_batches(threshold, 0)}
  end

  defp expire_batches(threshold, total) do
    batch_ids =
      threshold
      |> inactive_conversations_query()
      |> select([c], c.id)
      |> limit(@expire_batch_size)

    # The status/updated_at conditions are repeated on the outer UPDATE so they
    # are re-checked under the row lock: a conversation that received an
    # activity after the subquery ran is not closed.
    query =
      from(c in inactive_conversations_query(threshold),
        where: c.id in subquery(batch_ids),
        select: c
      )

    {count, closed} =
      Repo.update_all(query, set: [status: @closed, updated_at: DateTime.utc_now()])

    Enum.each(closed, &emit_lifecycle_event(&1, "expired"))

    if count < @expire_batch_size,
      do: total + count,
      else: expire_batches(threshold, total + count)
  end

  @doc "True for the `conversationUpdate` activities emitted by status changes."
  def lifecycle_event?(%{type: "conversationUpdate", sender: "system"}), do: true
  def lifecycle_event?(_activity), do: false

  defp emit_lifecycle_event(%Conversation{} = conversation, reason) do
    attrs = %{
      "tenant_id" => conversation.tenant_id,
      "conversation_id" => conversation.id,
      "type" => "conversationUpdate",
      "sender" => "system",
      "metadata" => %{
        "event" => "conversation_#{event_name(conversation.status)}",
        "status" => conversation.status,
        "reason" => to_string(reason)
      }
    }

    case Converger.Activities.create_activity(attrs, allow_closed: true) do
      {:ok, _activity} ->
        :ok

      {:error, error} ->
        Logger.error("Failed to emit conversation lifecycle event",
          conversation_id: conversation.id,
          status: conversation.status,
          error: inspect(error)
        )

        :error
    end
  end

  defp event_name(@closed), do: "closed"
  defp event_name(@open), do: "reopened"

  @doc """
  Deletes a conversation. Its activities and their deliveries (partitioned
  tables without foreign keys, ADR-0026) are purged by a
  `Converger.Workers.PurgeWorker` job enqueued in the same transaction.
  """
  def delete_conversation(%Conversation{} = conversation) do
    Ecto.Multi.new()
    |> Ecto.Multi.delete(:conversation, conversation)
    |> Oban.insert(
      :purge,
      Converger.Workers.PurgeWorker.new(%{conversation_ids: [conversation.id]})
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{conversation: deleted}} -> {:ok, deleted}
      {:error, :conversation, changeset, _} -> {:error, changeset}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  def change_conversation(%Conversation{} = conversation, attrs \\ %{}) do
    Conversation.changeset(conversation, attrs)
  end
end
