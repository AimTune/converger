defmodule ConvergerWeb.Protocol.ChannelSession do
  @moduledoc """
  A channel-scoped Converger Protocol v1 connection (docs/protocol/v1.md,
  section 10): a `scope: "channel"` token of a `websocket` channel follows
  every conversation of its channel. Agent consoles, the `@converger/agent`
  SDKs (#67) and the mekik transport (#64, Mode B) connect this way.

  `ConvergerWeb.Protocol.Session` runs the connection (limits, heartbeat,
  token refresh, draining) and hands this module the handshake of a channel
  token and every later frame and message. Connection-level frames travel
  bare; every conversation-level frame, both ways, is wrapped as
  `{conversationId, frame}` (`ConvergerWeb.Protocol.Frames.envelope/2`).

  ## Following conversations

  A conversation is **followed** (its frames are delivered) once

    * it is listed in `hello.watermarks` (replayed after the watermark),
    * something is delivered for it to the channel (a user turn routed to
      the channel, a forwarded bot-only frame such as `resume`), or
    * the connection sends a frame for it (a reply, `sync`, `typing`, ...).

  The conversation must be **owned** (of this channel) or **routed** (an
  enabled routing rule targets this channel from the conversation's channel),
  see `ConvergerWeb.Protocol.Access`. An owned conversation receives every
  activity as it is committed; a routed one receives what the pipeline
  delivers to the channel (after the channel's middleware), and replays and
  gap fills read the transcript through the same middleware. At most
  `limits.maxConversations` are followed: following one more evicts the least
  recently active, with `too_many_subscriptions` in its envelope.

  ## Agent groups

  `hello.group` (a Converger addition) puts the connection in a group of the
  channel. The connections of a group share the channel's conversations: each
  conversation is served by exactly one live member (rendezvous hashing over
  the `:pg` group, on every node), so several agent processes can run behind
  one channel without duplicate replies. A connection without a group sees
  every conversation (an agent console).

  ## The agent's frames

    * message frames (`text` and every message type) and mekik-native
      persistent frames (`tool_call`, `genui`, `interrupt`,
      `interrupt_resolved`, `skill`) are stored in the conversation as the
      agent's (`hello.userId` or the token's `user_id`, else `"agent"`), with
      this channel as the source, so reply-back routing delivers them to the
      end user's channel. A message frame keeps its `id`. A `clientId` (or a
      mekik message `id`) makes the send idempotent and draws an `ack`;
    * transient `run`, `genui_components`, `skills`, `error` are relayed to
      the conversation's connections (`ConvergerWeb.Protocol.BotRelay`);
    * `typing`, `read` and `sync` work as on a conversation connection; on a
      channel that requires acks, `read` also acknowledges the deliveries.

  The agent receives the end users' bot-only frames (`resume`, `genui_event`,
  ...) as they were sent, a user turn's `meta` on its frame, and a user turn
  that answers an open interrupt as `resume` (section 9).
  """

  alias Converger.Activities.MessagePayload
  alias Converger.Channels.Adapters.WebSocket
  alias Converger.{Conversations, Deliveries, Inbound, Pipeline, RateLimit}
  alias Converger.Conversations.Conversation
  alias ConvergerWeb.{ConversationSignals, Protocol}
  alias ConvergerWeb.Protocol.{Access, AgentGroups, BotRelay, Feed, Frames, Send}

  # A user turn's meta waits this long for its turn to be delivered.
  @meta_ttl_ms 60_000

  @connection_frames ~w(hello auth ping)

  @doc "Whether claims open a channel-scoped connection."
  def channel_token?(%{"scope" => "channel"} = claims), do: is_nil(claims["conversation_id"])
  def channel_token?(_claims), do: false

  @doc """
  Start the session after the handshake checks. Returns `{:ok, frames, state}`
  (welcome and replays, bare and enveloped) or `{:error, reason}`.
  """
  def start(hello, claims, channel, state) do
    if channel.type == "websocket" do
      {:ok, do_start(hello, claims, channel, state)}
    else
      {:error, :channel_type}
    end
  end

  defp do_start(hello, claims, channel, state) do
    Phoenix.PubSub.subscribe(Converger.PubSub, WebSocket.channel_topic(channel.id))
    track(claims, channel)

    group = group(hello["group"])
    if group, do: :pg.join(AgentGroups, {channel.id, group}, self())

    state =
      Map.merge(state, %{
        phase: :ready,
        mode: :channel,
        claims: claims,
        channel: channel,
        group: group,
        agent: agent_sender(claims, hello),
        participant: ConversationSignals.participant(claims),
        follows: %{},
        typing: %{},
        pending_meta: %{}
      })

    welcome =
      Frames.channel_welcome(%{
        channel_id: channel.id,
        connection_id: state.connection_id,
        expires_at: claims["exp"] * 1000
      })

    {frames, state} =
      (hello["watermarks"] || %{})
      |> listed_watermarks()
      |> Enum.reduce({[], state}, fn {conversation_id, watermark}, {acc, state} ->
        {frames, state} = follow_from(conversation_id, watermark, state)
        {acc ++ frames, state}
      end)

    {[welcome | frames], state}
  end

  defp listed_watermarks(watermarks) when is_map(watermarks) do
    watermarks
    |> Enum.filter(fn {id, _watermark} -> is_binary(id) end)
    |> Enum.take(Protocol.config(:max_conversations))
  end

  defp listed_watermarks(_watermarks), do: []

  defp group(group) when is_binary(group) and byte_size(group) in 1..128, do: group
  defp group(_group), do: nil

  defp agent_sender(%{"user_id" => user_id}, _hello) when is_binary(user_id) and user_id != "",
    do: user_id

  defp agent_sender(_claims, %{"userId" => user_id})
       when is_binary(user_id) and byte_size(user_id) in 1..256,
       do: user_id

  defp agent_sender(_claims, _hello), do: "agent"

  defp track(claims, channel) do
    socket_id = ConvergerWeb.Sockets.converger_socket_id(claims)

    if socket_id do
      Phoenix.PubSub.subscribe(Converger.PubSub, socket_id)

      ConvergerWeb.Sockets.track_id(socket_id, channel.id, %{
        tenant_id: channel.tenant_id,
        scope: "channel",
        transport: "converger/1"
      })
    end
  end

  ## Frames from the agent

  @doc """
  A frame after the handshake (not `ping`, `auth` or `hello`, which the
  session answers). Returns `{frames, state}`.
  """
  def handle_frame(
        %{"conversationId" => conversation_id, "frame" => %{} = frame} = envelope,
        state
      )
      when not is_map_key(envelope, "type") and is_binary(conversation_id) do
    case ensure_followed(conversation_id, state) do
      {:ok, frames, state} ->
        {more, state} = conversation_frame(conversation_id, frame, touch(state, conversation_id))
        {frames ++ more, state}

      :error ->
        frame =
          Frames.error("conversation_not_found", "conversation not found",
            frame_type: frame["type"]
          )

        {[Frames.envelope(conversation_id, frame)], state}
    end
  end

  def handle_frame(%{"type" => type}, state)
      when is_binary(type) and type not in @connection_frames do
    message =
      "on a channel-scoped connection, conversation frames are sent as {conversationId, frame}"

    {[Frames.error("bad_request", message, frame_type: type)], state}
  end

  def handle_frame(_frame, state) do
    {[Frames.error("bad_request", "a frame needs a string type or a conversation envelope")],
     state}
  end

  defp conversation_frame(id, %{"type" => "typing", "isTyping" => typing?}, state)
       when is_boolean(typing?) do
    if permitted?(state, "typing") do
      current = Map.get(state.typing, id, ConversationSignals.new_typing())
      typing = ConversationSignals.typing(current, id, state.participant, typing?)
      {[], %{state | typing: Map.put(state.typing, id, typing)}}
    else
      {[envelope_error(id, insufficient_permission("typing", "typing"))], state}
    end
  end

  defp conversation_frame(id, %{"type" => "read"} = frame, state) do
    case ConversationSignals.read(id, state.participant, frame["watermark"]) do
      {:ok, read_seq} ->
        if is_integer(read_seq), do: Deliveries.acknowledge(state.channel.id, id, read_seq)
        {[], state}

      {:error, _} ->
        message = "read needs a watermark of at least 1"

        {[envelope_error(id, Frames.error("invalid_watermark", message, frame_type: "read"))],
         state}
    end
  end

  defp conversation_frame(id, %{"type" => "sync"} = frame, state) do
    head = Conversations.get_conversation(id).last_seq

    case Protocol.parse_watermark(frame["watermark"]) do
      {:ok, {:seq, seq}} when seq > head ->
        message = "watermark #{seq} is above the head #{head}"

        {[envelope_error(id, Frames.error("invalid_watermark", message, frame_type: "sync"))],
         state}

      {:ok, position} ->
        replay(id, position || {:seq, 0}, head, state)

      {:error, _} ->
        error = Frames.error("invalid_watermark", "invalid watermark", frame_type: "sync")
        {[envelope_error(id, error)], state}
    end
  end

  defp conversation_frame(id, %{"type" => type} = frame, state) when is_binary(type) do
    cond do
      type in BotRelay.transient_types() ->
        BotRelay.relay(id, frame)
        {[], state}

      type in BotRelay.forwarded_types() or type in ~w(hello welcome ack) ->
        error = Frames.error("bad_request", "#{type} is not an agent frame", frame_type: type)
        {[envelope_error(id, error)], state}

      MessagePayload.native?(type) or Send.kind(type) in [:text, :rich] ->
        persist(id, frame, state)

      true ->
        {[
           envelope_error(id, Frames.error("bad_request", "unknown frame type", frame_type: type))
         ], state}
    end
  end

  defp conversation_frame(id, _frame, state) do
    {[envelope_error(id, Frames.error("bad_request", "a frame needs a string type"))], state}
  end

  ## Storing the agent's frames

  defp persist(id, frame, state) do
    type = frame["type"]

    with true <- permitted?(state, "write") || {:error, :write},
         {:ok, client_id} <- client_id(frame),
         {:ok, params} <- bot_params(frame),
         :ok <- rate_limit(state.claims) do
      key = client_id && BotRelay.client_key(state.agent, id, client_id)

      message =
        Map.merge(params, %{"sender" => state.agent, "idempotency_key" => key})

      # Inbound de-duplicates per channel; a routed conversation belongs to
      # another channel, so a resend is recognised here first.
      result =
        case Converger.Activities.get_activity_by_idempotency_key(id, key) do
          nil -> Inbound.receive_message(state.channel, message, conversation_id: id)
          existing -> {:duplicate, existing}
        end

      persisted(id, result, client_id, type, state)
    else
      {:error, :write} ->
        {[envelope_error(id, insufficient_permission("write", type))], state}

      {:error, code, message, opts} ->
        {[envelope_error(id, Frames.error(code, message, [frame_type: type] ++ opts))], state}
    end
  end

  # A mekik bot.s message `id` is its clientId when it has the clientId syntax.
  # A mekik-native frame.s `id` names the interrupt (an `interrupt` and its
  # `interrupt_resolved` share it), so only an explicit clientId counts there.
  defp client_id(%{"type" => type} = frame) do
    if MessagePayload.native?(type),
      do: Send.client_id(Map.delete(frame, "id")),
      else: Send.client_id(frame)
  end

  defp bot_params(%{"type" => type} = frame) do
    metadata = Map.get(frame, "metadata") || %{}

    cond do
      not is_map(metadata) ->
        {:error, "bad_request", "metadata must be an object", []}

      not MessagePayload.native?(type) and not is_map(frame["data"]) ->
        {:error, "bad_request", "a #{type} frame needs a data object", []}

      true ->
        base = %{"type" => "message", "metadata" => metadata, "reply_to_id" => reply_to_id(frame)}
        {:ok, Map.merge(base, content_params(frame))}
    end
  end

  defp reply_to_id(%{"replyTo" => %{"id" => id}}) when is_binary(id), do: id
  defp reply_to_id(_frame), do: nil

  defp content_params(frame) do
    case MessagePayload.from_frame(frame, keep_id: true) do
      :plain ->
        %{
          "text" => frame["data"]["text"],
          "attachments" => frame["data"]["attachments"] || []
        }

      {:ok, type, payload} ->
        %{"message_type" => type, "payload" => payload}
    end
  end

  defp rate_limit(%{"tenant_id" => tenant_id}) do
    case RateLimit.check(:activity_create, "tenant:#{tenant_id}", tenant: tenant_id) do
      {:allow, _count} ->
        :ok

      {:deny, retry_after_ms, _spec} ->
        {:error, "rate_limited", "too many messages", [retry_after_ms: retry_after_ms]}
    end
  end

  defp persisted(id, {tag, activity}, client_id, _type, state)
       when tag in [:created, :duplicate] do
    state = update_feed(state, id, &Feed.own(&1, activity.seq))

    frames =
      if client_id,
        do: [Frames.envelope(id, Frames.ack(activity, client_id, tag == :duplicate))],
        else: []

    {frames, state}
  end

  defp persisted(id, result, client_id, type, state) do
    opts = [client_id: client_id, frame_type: type]

    error =
      case result do
        {:rejected, changeset} ->
          Frames.error(
            "invalid_message",
            "the message failed validation",
            [details: Frames.changeset_details(changeset)] ++ opts
          )

        {:error, :conversation_closed} ->
          Frames.error("conversation_closed", "the conversation is closed", opts)

        {:error, :inbound_not_supported} ->
          Frames.error("forbidden", "the channel does not accept messages (mode outbound)", opts)

        {:error, _reason} ->
          Frames.error("internal", "the message could not be accepted, retry", opts)
      end

    {[envelope_error(id, error)], state}
  end

  ## Messages of the connection process

  @doc "A message of the connection process. Returns `{frames, state}`."
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "channel:" <> _,
          event: "new_activity",
          payload: activity
        },
        state
      ) do
    # A delivery to the channel, after its middleware: discovers conversations.
    deliver_live(activity.conversation_id, activity, [prepared: true], state)
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "channel:" <> _, event: "bot_frame", payload: payload},
        state
      ) do
    %{conversation_id: id, frame: frame} = payload

    if serves?(state, id) do
      case ensure_followed(id, state) do
        {:ok, frames, state} -> {frames ++ [Frames.envelope(id, frame)], touch(state, id)}
        :error -> {[], state}
      end
    else
      {[], state}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "channel:" <> _, event: "turn_meta", payload: payload},
        state
      ) do
    %{conversation_id: id, key: key, meta: meta} = payload
    expires = System.monotonic_time(:millisecond) + @meta_ttl_ms
    pending = Map.put(prune_meta(state.pending_meta), {id, key}, {meta, expires})
    {[], %{state | pending_meta: pending}}
  end

  # Every activity of an owned conversation, as it is committed.
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "conversation:" <> rest,
          event: "new_activity",
          payload: activity
        },
        state
      ) do
    case Map.get(state.follows, rest) do
      %{source: :owned} -> deliver_live(rest, activity, [], state)
      _ -> {[], state}
    end
  end

  # Receipts, typing and presence of followed conversations.
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "conversation:" <> rest, event: event, payload: payload},
        state
      )
      when event in ~w(delivery_status typing read presence_diff) do
    id = conversation_of_topic(rest)

    if Map.has_key?(state.follows, id) do
      frames =
        event
        |> ConversationSignals.frames(payload, id, state.participant)
        |> Enum.map(fn {_kind, frame} -> Frames.envelope(id, frame) end)

      {frames, state}
    else
      {[], state}
    end
  end

  def handle_info(_message, state), do: {[], state}

  @doc "The connection ended: stop every typing indicator and leave the group."
  def terminate(state) do
    Enum.each(state.typing, fn {id, typing} ->
      ConversationSignals.stop_typing(typing, id, state.participant)
    end)

    if state.group, do: :pg.leave(AgentGroups, {state.channel.id, state.group}, self())
    :ok
  end

  defp conversation_of_topic(rest), do: rest |> String.split(":") |> hd()

  defp deliver_live(id, activity, opts, state) do
    if serves?(state, id) do
      case ensure_followed(id, state, Map.get(activity, :seq)) do
        {:ok, frames, state} ->
          entry = Map.fetch!(state.follows, id)
          {live, feed} = Feed.live(entry.feed, activity, opts)
          {metas, state} = take_meta(state, id, activity)
          state = put_feed(touch(state, id), id, feed)
          {frames ++ envelope_all(id, live, metas), state}

        :error ->
          {[], state}
      end
    else
      {[], unfollow(state, id)}
    end
  end

  ## Following

  # {:ok, frames, state} once the conversation is followed (frames: evictions),
  # or :error when the token may not follow it. `live_seq` (a live activity's
  # seq) starts a newly followed conversation just before that activity.
  defp ensure_followed(id, state, live_seq \\ nil) do
    if Map.has_key?(state.follows, id) do
      {:ok, [], state}
    else
      with {:ok, source, conversation} <- Access.conversation(id, state.channel, state.claims) do
        {evicted, state} = make_room(state)
        state = follow(conversation, source, state)

        state =
          case live_seq do
            seq when is_integer(seq) and seq > 0 ->
              update_feed(state, id, &Feed.seek(&1, seq - 1))

            _ ->
              update_feed(state, id, &Feed.seek(&1, conversation.last_seq))
          end

        {:ok, evicted, state}
      end
    end
  end

  defp follow_from(id, watermark, state) do
    with {:ok, position} <- Protocol.parse_watermark(watermark),
         {:ok, source, conversation} <- Access.conversation(id, state.channel, state.claims),
         true <- serves?(state, conversation.id) do
      {evicted, state} = make_room(state)
      state = follow(conversation, source, state)

      {frames, state} =
        replay(conversation.id, position || {:seq, 0}, conversation.last_seq, state)

      {evicted ++ frames, state}
    else
      _ -> {[], state}
    end
  end

  defp follow(%Conversation{id: id} = conversation, source, state) do
    Phoenix.PubSub.subscribe(Converger.PubSub, "conversation:#{id}")
    ConversationSignals.subscribe(id, false)

    viewer = {:agent, state.agent, Conversation.origin_channel_id(conversation)}
    feed = Feed.new(id, viewer, prepare: prepare(source, state.channel))

    entry = %{feed: feed, source: source, active_at: System.monotonic_time()}
    %{state | follows: Map.put(state.follows, id, entry)}
  end

  # A routed conversation is seen as delivered to the channel: its middleware
  # and the matching rules' transformations apply.
  defp prepare(:routed, channel) do
    fn activity ->
      case Pipeline.transform(activity, channel) do
        {:ok, transformed} -> {:ok, transformed}
        {:halt, _reason} -> :skip
      end
    end
  end

  defp prepare(:owned, _channel), do: nil

  defp unfollow(state, id) do
    if Map.has_key?(state.follows, id) do
      Phoenix.PubSub.unsubscribe(Converger.PubSub, "conversation:#{id}")
      ConversationSignals.unsubscribe(id, state.participant)
      %{state | follows: Map.delete(state.follows, id)}
    else
      state
    end
  end

  defp make_room(state) do
    max = Protocol.config(:max_conversations)

    if map_size(state.follows) >= max do
      {id, _entry} = Enum.min_by(state.follows, fn {_id, entry} -> entry.active_at end)

      error =
        Frames.error(
          "too_many_subscriptions",
          "following more than #{max} conversations; this one is no longer delivered live, sync it to resume"
        )

      {[Frames.envelope(id, error)], unfollow(state, id)}
    else
      {[], state}
    end
  end

  defp replay(id, position, head, state) do
    entry = Map.fetch!(state.follows, id)
    {frames, feed} = Feed.replay(entry.feed, position, head)

    if not WebSocket.require_ack?(state.channel) and head > 0,
      do: Deliveries.acknowledge(state.channel.id, id, head)

    state = put_feed(state, id, feed)
    {envelope_all(id, frames, %{}), state}
  end

  # Rendezvous hashing over the live members of the connection's group: the
  # member with the highest hash serves the conversation.
  defp serves?(%{group: nil}, _id), do: true

  defp serves?(state, id) do
    case :pg.get_members(AgentGroups, {state.channel.id, state.group}) do
      [] -> true
      members -> Enum.max_by(members, &:erlang.phash2({id, &1})) == self()
    end
  end

  ## Helpers

  # `metas`: seq => the mekik/1 meta of that user turn.
  defp envelope_all(id, frames, metas) do
    Enum.map(frames, fn frame ->
      frame = frame |> BotRelay.turn_frame(id) |> put_meta(metas)
      Frames.envelope(id, frame)
    end)
  end

  defp put_meta(%{"seq" => seq} = frame, metas) when is_map_key(metas, seq),
    do: Map.put(frame, "meta", Map.fetch!(metas, seq))

  defp put_meta(frame, _metas), do: frame

  # A turn's meta was relayed ahead of it, under its idempotency key.
  defp take_meta(state, id, activity) do
    case Map.pop(state.pending_meta, {id, Map.get(activity, :idempotency_key)}) do
      {{meta, _expires}, pending} -> {%{activity.seq => meta}, %{state | pending_meta: pending}}
      {nil, _pending} -> {%{}, state}
    end
  end

  defp prune_meta(pending) do
    now = System.monotonic_time(:millisecond)
    pending |> Enum.reject(fn {_key, {_meta, expires}} -> expires < now end) |> Map.new()
  end

  defp touch(state, id) do
    case Map.get(state.follows, id) do
      nil -> state
      entry -> put_entry(state, id, %{entry | active_at: System.monotonic_time()})
    end
  end

  defp update_feed(state, id, fun) do
    case Map.get(state.follows, id) do
      nil -> state
      entry -> put_entry(state, id, %{entry | feed: fun.(entry.feed)})
    end
  end

  defp put_feed(state, id, feed), do: update_feed(state, id, fn _ -> feed end)

  defp put_entry(state, id, entry), do: %{state | follows: Map.put(state.follows, id, entry)}

  defp permitted?(state, permission), do: Map.has_key?(state.permitted, permission)

  defp envelope_error(id, error), do: Frames.envelope(id, error)

  defp insufficient_permission(permission, frame_type) do
    Frames.error("insufficient_permission", "the token lacks the #{permission} permission",
      frame_type: frame_type,
      details: %{"required" => permission}
    )
  end
end
