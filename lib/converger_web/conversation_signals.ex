defmodule ConvergerWeb.ConversationSignals do
  @moduledoc """
  Transient conversation signals for every client transport: delivery and
  read receipts, typing indicators and presence (docs/protocol/v1.md,
  section 8; ADR-0032).

  Used by the Phoenix channel binding (`ConvergerWeb.ConvergerChannel`), the
  native v1 WebSocket (`ConvergerWeb.ProtocolSocket`) and the Server-Sent
  Events stream (`ConvergerWeb.ConvergerAPI.EventStreamController`), so the
  three behave the same. A connection process:

    1. `subscribe/2`s to the conversation's signals (and presence) topics,
    2. turns each broadcast into frames with `frames/4` (built by
       `ConvergerWeb.ConvergerFrames`), and
    3. reports its own participant's `typing/4` and `read/3`.

  A **participant** is the `%{id, role}` identity of a connection, from its
  token (`participant/1`).
  """

  alias Converger.{Channels, Conversations, Receipts}
  alias Converger.Channels.Signals
  alias Converger.ConvergerAPI.Watermark
  alias ConvergerWeb.{ConvergerFrames, ConversationPresence}

  # A client sends at most one typing frame per 2 s (protocol v1, section 11);
  # repeats of the same state inside the window are dropped silently.
  @typing_interval_ms 2_000

  # External typing indicators (WhatsApp) last ~25 s, so a connection that
  # keeps typing refreshes them at most this often.
  @typing_forward_interval_ms 20_000

  @typedoc "Typing state of one connection: the last state sent and when it was forwarded."
  @type typing_state :: %{typing: nil | {boolean(), integer()}, forwarded_at: nil | integer()}

  @doc "The signals topic of a conversation (typing, read receipts)."
  def topic(conversation_id), do: "conversation:#{conversation_id}:signals"

  @doc """
  The participant identity of a connection, from its token claims: the
  token's `user_id`, or `"anonymous"` without one.

  Client tokens are conversation tokens of end users, so every participant
  has role `"user"` for now; agent consoles get their own role with
  channel-scoped sockets (#64/#67).
  """
  def participant(claims) do
    case claims["user_id"] do
      user_id when is_binary(user_id) and user_id != "" -> %{id: user_id, role: "user"}
      _ -> %{id: "anonymous", role: "user"}
    end
  end

  @doc """
  Whether presence is on for a connection. The conversation's channel decides
  (config key `"presence"`):

    * `"identified"` (default) - every connection with a `user_id`
    * `"all"` - anonymous end users too (one `"anonymous"` participant)
    * `"off"` - no presence frames at all
  """
  def presence?(claims) do
    mode =
      case Channels.get_active_channel(claims["channel_id"], claims["tenant_id"]) do
        {:ok, channel} -> (channel.config || %{})["presence"]
        _ -> "off"
      end

    case mode do
      "off" -> false
      "all" -> true
      _ -> participant(claims).id != "anonymous"
    end
  end

  @doc "Subscribe the calling process to the signals (and, if on, presence) of a conversation."
  def subscribe(conversation_id, presence?) do
    Phoenix.PubSub.subscribe(Converger.PubSub, topic(conversation_id))

    if presence?,
      do: Phoenix.PubSub.subscribe(Converger.PubSub, ConversationPresence.topic(conversation_id))

    :ok
  end

  @doc "Undo `subscribe/2` and `track_presence/2` (for processes that outlive a stream)."
  def unsubscribe(conversation_id, participant) do
    Phoenix.PubSub.unsubscribe(Converger.PubSub, topic(conversation_id))
    Phoenix.PubSub.unsubscribe(Converger.PubSub, ConversationPresence.topic(conversation_id))

    ConversationPresence.untrack(
      self(),
      ConversationPresence.topic(conversation_id),
      participant.id
    )

    :ok
  end

  @doc """
  The frames a broadcast on the conversation, signals or presence topic
  becomes for a connection of `participant`, each tagged `:reliable` or
  `:ephemeral` (typing and presence, which a lagging connection may drop).
  Returns `[]` for broadcasts that are not signals or not for this connection.
  """
  @spec frames(String.t(), map(), String.t(), map()) :: [{:reliable | :ephemeral, map()}]
  def frames("delivery_status", payload, _conversation_id, participant) do
    if delivery_status_visible?(participant, payload),
      do: [{:reliable, ConvergerFrames.delivery_status(payload)}],
      else: []
  end

  def frames("typing", payload, _conversation_id, participant) do
    if payload.participant.id != participant.id,
      do: [{:ephemeral, ConvergerFrames.typing(payload.is_typing, payload.participant)}],
      else: []
  end

  def frames("read", payload, _conversation_id, participant) do
    if payload.by.id != participant.id,
      do: [{:reliable, ConvergerFrames.read_receipt(payload.up_to_seq, payload.by, payload.at)}],
      else: []
  end

  def frames("presence_diff", diff, conversation_id, participant) do
    topic = ConversationPresence.topic(conversation_id)
    now = DateTime.utc_now()

    (Map.keys(diff.joins) ++ Map.keys(diff.leaves))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == participant.id))
    |> Enum.map(fn id ->
      metas =
        case ConversationPresence.get_by_key(topic, id) do
          %{metas: metas} -> metas
          _ -> []
        end

      meta =
        List.first(metas) || List.first(get_in(diff, [:leaves, id, :metas]) || []) ||
          List.first(get_in(diff, [:joins, id, :metas]) || [])

      {:ephemeral, ConvergerFrames.presence(presence_participant(id, meta), length(metas), now)}
    end)
  end

  def frames(_event, _payload, _conversation_id, _participant), do: []

  # Every connection of the conversation sees delivery progress, except
  # identified end users, who only see it for their own activities.
  defp delivery_status_visible?(%{role: "user", id: id}, payload) when id != "anonymous",
    do: Map.get(payload, :sender) == id

  defp delivery_status_visible?(_participant, _payload), do: true

  ## Typing

  @doc "A connection's initial typing state."
  @spec new_typing() :: typing_state()
  def new_typing, do: %{typing: nil, forwarded_at: nil}

  @doc """
  `participant` started or stopped typing on this connection: relayed to the
  conversation's other connections and, when the adapter supports it, to the
  external channel. Repeats of the same state within 2 s are dropped.
  Returns the new typing state.
  """
  @spec typing(typing_state(), String.t(), map(), boolean()) :: typing_state()
  def typing(state, conversation_id, participant, is_typing) when is_boolean(is_typing) do
    now = System.monotonic_time(:millisecond)

    case state.typing do
      {^is_typing, at} when now - at < @typing_interval_ms ->
        state

      _ ->
        broadcast_typing(conversation_id, participant, is_typing)
        state = %{state | typing: {is_typing, now}}

        if is_typing,
          do: maybe_forward_typing(state, conversation_id, participant, now),
          else: state
    end
  end

  @doc """
  A connection that closes while its participant is typing clears the
  indicator for the others instead of leaving it to expire.
  """
  def stop_typing(%{typing: {true, _at}}, conversation_id, participant),
    do: broadcast_typing(conversation_id, participant, false)

  def stop_typing(_state, _conversation_id, _participant), do: :ok

  defp broadcast_typing(conversation_id, participant, is_typing) do
    ConvergerWeb.Endpoint.broadcast_from(self(), topic(conversation_id), "typing", %{
      participant: participant,
      is_typing: is_typing
    })
  end

  defp maybe_forward_typing(state, conversation_id, participant, now) do
    case state.forwarded_at do
      at when is_integer(at) and now - at < @typing_forward_interval_ms ->
        state

      _ ->
        Signals.forward_typing(conversation_id, participant.id, true)
        %{state | forwarded_at: now}
    end
  end

  ## Read receipts

  @doc """
  `participant` has read everything up to `watermark` (the v1 integer seq,
  its decimal string form, or an opaque `seq:<n>` watermark). The stored
  position never moves backwards; when it advances, the other connections
  get a read receipt and the external channels are told.

  Returns `{:ok, read_seq}` (the stored position) or
  `{:error, :invalid_watermark | :not_found}`.
  """
  def read(conversation_id, participant, watermark) do
    with {:ok, watermark} <- read_watermark(watermark),
         %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id) do
      case Receipts.mark_read(conversation, participant.id, watermark) do
        {:ok, :advanced, read_seq} ->
          ConvergerWeb.Endpoint.broadcast(topic(conversation_id), "read", %{
            up_to_seq: read_seq,
            by: participant,
            at: DateTime.utc_now()
          })

          Signals.forward_read(conversation_id, participant.id, read_seq)
          {:ok, read_seq}

        {:ok, :unchanged, read_seq} ->
          {:ok, read_seq}

        {:error, :invalid_watermark} ->
          {:error, :invalid_watermark}
      end
    else
      {:error, :invalid_watermark} -> {:error, :invalid_watermark}
      nil -> {:error, :not_found}
    end
  end

  defp read_watermark(seq) when is_integer(seq) and seq >= 1, do: {:ok, seq}

  defp read_watermark(watermark) when is_binary(watermark) do
    case Integer.parse(watermark) do
      {seq, ""} when seq >= 1 ->
        {:ok, seq}

      _ ->
        case Watermark.decode(watermark) do
          {:ok, {:seq, seq}} when seq >= 1 -> {:ok, seq}
          _ -> {:error, :invalid_watermark}
        end
    end
  end

  defp read_watermark(_watermark), do: {:error, :invalid_watermark}

  ## Presence

  @doc "Track the calling connection as online for `participant` (when presence is on)."
  def track_presence(conversation_id, participant) do
    ConversationPresence.track(
      self(),
      ConversationPresence.topic(conversation_id),
      participant.id,
      %{role: participant.role, online_at: System.system_time(:millisecond)}
    )
  end

  @doc "`presence` frames for who is already online, except `participant` itself."
  def presence_snapshot(conversation_id, participant) do
    now = DateTime.utc_now()

    conversation_id
    |> ConversationPresence.topic()
    |> ConversationPresence.list()
    |> Enum.reject(fn {id, _} -> id == participant.id end)
    |> Enum.map(fn {id, %{metas: metas}} ->
      ConvergerFrames.presence(presence_participant(id, List.first(metas)), length(metas), now)
    end)
  end

  defp presence_participant(id, %{role: role}), do: %{id: id, role: role}
  defp presence_participant(id, _meta), do: %{id: id}
end
