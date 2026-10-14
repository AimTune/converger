defmodule ConvergerWeb.Protocol.Session do
  @moduledoc """
  One Converger Protocol v1 connection to one conversation
  (docs/protocol/v1.md), independent of the transport that carries it.

  The session runs in the connection's process and works on decoded frames
  (string-keyed maps, the JSON shapes of the spec). A transport decodes what
  it receives, hands it to `handle_in/3`, routes every other message of its
  process to `handle_info/2`, and turns the results into its own wire
  messages:

    * `{:ok, session}`: nothing to send;
    * `{:push, frames, session}`: send `frames`, in order;
    * `{:close, close, frames, session}`: send `frames`, then close the
      connection. `close` is `%{code: code, reason: reason, retry_after_ms:
      ms | nil}` with the WebSocket close code of section 12.3.

  Transports: the native WebSocket endpoint (`ConvergerWeb.ProtocolSocket`)
  and the gRPC stream (`ConvergerWeb.GRPC.ChannelStreamServer`, ADR-0056).
  Both therefore share the handshake, replay, acks, idempotency, limits,
  receipts, typing, presence, token refresh and draining:

      client -> hello
      server -> welcome, replay (seq > hello.watermark), live frames
      client -> text {clientId}      server -> ack {clientId, id, seq}
      client -> sync {watermark}     server -> replay
      client -> ping                 server -> heartbeat
      client -> auth {token}         server -> tokenRefreshed
      client -> typing {isTyping}    others -> typing
      client -> read {watermark}     others -> deliveryStatus {upToSeq, status: read}
      server -> deliveryStatus, presence

  Ordering, de-duplication, gap filling and the echo rule are
  `ConvergerWeb.Protocol.Feed`; frames are `ConvergerWeb.Protocol.Frames`;
  receipts, typing and presence are `ConvergerWeb.ConversationSignals`.

  Limits are the client WebSocket limits of `config :converger, :websocket`
  (`ConvergerWeb.SocketGuard`): frame size, inbound frames per window,
  ephemeral frames dropped and a 4503 close for a client that does not keep
  up. On shutdown the session is closed with 1012
  (`ConvergerWeb.ProtocolConnections`).

  Close codes (section 12.3): 4400 unsupported protocol, 4401 unauthorized or
  token expired, 4403 channel deactivated or forced disconnect, 4408 idle
  timeout, 4503 slow consumer, 1012 node draining, 1013 database unavailable
  during the handshake, 1008 when the conversation cannot be resolved.
  """

  require Logger

  alias Converger.{Activities, Channels, Conversations, Inbound, RateLimit}
  alias Converger.Auth.ConvergerToken
  alias Converger.Repo.Pressure
  alias ConvergerWeb.{ClientConnections, ConversationSignals, Protocol, SocketGuard}
  alias ConvergerWeb.Protocol.{BotRelay, ChannelSession, Feed, Frames, Send}

  # Frames a client sends that need a bot channel (mekik relay, #64).
  @bot_frames BotRelay.forwarded_types()

  # Messages a channel-scoped session handles itself (ChannelSession).
  @channel_events ~w(new_activity bot_frame turn_meta delivery_status typing read presence_diff)

  @type frame :: map()
  @type close :: %{code: pos_integer(), reason: String.t(), retry_after_ms: nil | pos_integer()}
  @type t :: map()
  @type result ::
          {:ok, t()} | {:push, [frame()], t()} | {:close, close(), [frame()], t()}

  @doc """
  A new session, in the calling (connection) process: it registers the
  connection for draining and the connection gauge and starts the heartbeat
  and idle timer.

  Options:

    * `:transport` (required): the `transport` label of the connection
      metrics, `"websocket"` or `"grpc"`;
    * `:handler` (required): the module named in `[:converger, :socket,
      :limit]` events;
    * `:token`: the credential taken from the transport (header, query or
      metadata); without one `hello.token` is used;
    * `:backlog`: a 0-arity function returning the frames buffered for the
      client (slow-consumer detection); defaults to this process's mailbox.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    now = now()
    transport = Keyword.fetch!(opts, :transport)

    state = %{
      phase: :awaiting_hello,
      # :conversation, or :channel for a channel-scoped token
      # (ConvergerWeb.Protocol.ChannelSession).
      mode: :conversation,
      transport: transport,
      handler: Keyword.fetch!(opts, :handler),
      backlog: Keyword.get(opts, :backlog, &own_backlog/0),
      token: Keyword.get(opts, :token),
      connection_id: Protocol.random_id("conn"),
      heartbeat_ms: Protocol.config(:heartbeat_interval_ms),
      idle_ms: Protocol.config(:idle_timeout_ms),
      max_frame_bytes: SocketGuard.config(:max_frame_bytes),
      last_in: now,
      last_out: now,
      claims: nil,
      # The token's permissions (ADR-0059), as a set for frame guards.
      permitted: %{},
      conversation_id: nil,
      user_id: nil,
      # `hello.protocol` as the client sent it (nil when absent): with no
      # negotiated subprotocol it selects the mekik/1 profile of the native
      # endpoint (ConvergerWeb.Protocol.MekikProfile).
      protocol: nil,
      feed: nil,
      expiry_timer: nil,
      participant: nil,
      typing: ConversationSignals.new_typing()
    }

    ConvergerWeb.ProtocolConnections.register()
    ClientConnections.connected("protocol", transport)
    schedule_tick(state)
    state
  end

  defp own_backlog, do: SocketGuard.queue_len(self())

  @doc "The `protocol` the client named in `hello`, or nil (absent, or no `hello` yet)."
  @spec protocol(t()) :: String.t() | nil
  def protocol(state), do: state.protocol

  @doc """
  An inbound frame of `size` bytes on the wire. `decode` is called only when
  the frame passes the rate and size limits, and returns `{:ok, frame}` or
  `{:error, message}` (answered with `bad_request`).
  """
  @spec handle_in(non_neg_integer(), (-> {:ok, frame()} | {:error, String.t()}), t()) ::
          result()
  def handle_in(size, decode, state) when is_function(decode, 0) do
    state = touch(state)
    Converger.Telemetry.ws_frame("protocol", state.transport, :in)

    cond do
      (retry_after = SocketGuard.rate_limited()) != nil ->
        SocketGuard.emit(:rate_limited, state.handler)
        frame = error("rate_limited", "too many frames", retry_after_ms: retry_after)
        reply([frame], state)

      size > state.max_frame_bytes ->
        SocketGuard.emit(:payload_too_large, state.handler)
        message = "frame exceeds #{state.max_frame_bytes} bytes"
        reply([error("payload_too_large", message)], state)

      true ->
        case decode.() do
          {:ok, frame} -> safe_handle_frame(frame, state)
          {:error, message} -> reply([Frames.error("bad_request", message)], state)
        end
    end
  end

  @doc "Inbound activity that is not a frame (WebSocket ping/pong) resets the idle timer."
  @spec touch(t()) :: t()
  def touch(state), do: %{state | last_in: now()}

  @doc "A message of the connection process that is not a client frame."
  @spec handle_info(term(), t()) :: result()
  def handle_info(%Phoenix.Socket.Broadcast{event: event} = broadcast, %{mode: :channel} = state)
      when state.phase == :ready and event in @channel_events do
    if event == "new_activity" and slow_consumer?(state) do
      SocketGuard.emit(:slow_consumer, state.handler)
      close_with_retry(4503, "slow_consumer", [], state)
    else
      {frames, state} = ChannelSession.handle_info(broadcast, state)
      reply(frames, state)
    end
  end

  # A bot's transient frame (run, genui_components, skills, error), relayed by
  # BotRelay to every connection of the conversation (section 9).
  def handle_info(%Phoenix.Socket.Broadcast{event: "bot_transient", payload: frame}, state)
      when state.phase == :ready and state.mode == :conversation,
      do: reply([frame], state)

  def handle_info(%Phoenix.Socket.Broadcast{event: "new_activity", payload: activity}, state)
      when state.phase == :ready do
    if slow_consumer?(state) do
      SocketGuard.emit(:slow_consumer, state.handler)
      close_with_retry(4503, "slow_consumer", [], state)
    else
      live(activity, state)
    end
  end

  # Receipts, typing and presence (ConversationSignals decides what this
  # connection sees). Typing and presence are dropped for a lagging client.
  def handle_info(%Phoenix.Socket.Broadcast{event: event, payload: payload}, state)
      when state.phase == :ready and event in ~w(delivery_status typing read presence_diff) do
    event
    |> ConversationSignals.frames(payload, state.conversation_id, state.participant)
    |> Enum.flat_map(fn
      {:reliable, frame} -> [frame]
      {:ephemeral, frame} -> ephemeral(frame, state)
    end)
    |> reply(state)
  end

  # Node draining (ConvergerWeb.ProtocolConnections.drain/0): reconnect elsewhere.
  def handle_info(:socket_drain, state), do: close_with_retry(1012, "unavailable", [], state)

  def handle_info(%Phoenix.Socket.Broadcast{event: "disconnect"}, state) do
    case Channels.get_active_channel(state.claims["channel_id"], state.claims["tenant_id"]) do
      {:ok, _channel} ->
        close(4403, "disconnected", [], state)

      _ ->
        close(4403, "channel inactive", [error("channel_inactive", "channel deactivated")], state)
    end
  end

  def handle_info(:tick, state) do
    now = now()
    schedule_tick(state)

    cond do
      now - state.last_in >= state.idle_ms ->
        close(4408, "idle timeout", [], state)

      state.phase == :ready and now - state.last_out >= state.heartbeat_ms ->
        reply([Frames.heartbeat(head_seq(state))], state)

      true ->
        {:ok, state}
    end
  end

  def handle_info(:token_expired, state) do
    close(4401, "token expired", [error("token_expired", "token expired, refresh it")], state)
  end

  def handle_info(_message, state), do: {:ok, state}

  @doc """
  The connection ended. Stops this participant's typing indicator and counts
  the disconnect. `reason` is the transport's (a WebSocket frame above the
  hard cap is reported as `[:converger, :socket, :limit]` `frame_too_large`).
  """
  @spec terminate(term(), t()) :: :ok
  def terminate(reason, %{phase: :ready, mode: :channel} = state) do
    ChannelSession.terminate(state)
    terminated(reason, state)
  end

  def terminate(reason, %{phase: :ready} = state) do
    ConversationSignals.stop_typing(state.typing, state.conversation_id, state.participant)
    terminated(reason, state)
  end

  def terminate(reason, state), do: terminated(reason, state)

  defp terminated(reason, state) do
    ClientConnections.disconnected("protocol", state.transport)
    limit_hit(reason, state)
    :ok
  end

  defp limit_hit({:error, :max_frame_size_exceeded}, state),
    do: SocketGuard.emit(:frame_too_large, state.handler)

  defp limit_hit(_reason, _state), do: :ok

  defp slow_consumer?(state),
    do: state.backlog.() > SocketGuard.config(:slow_consumer_queue_len)

  defp ephemeral(frame, state) do
    if state.backlog.() > SocketGuard.config(:ephemeral_drop_queue_len) do
      SocketGuard.emit(:ephemeral_dropped, state.handler)
      []
    else
      [frame]
    end
  end

  ## Database pressure (issue #35, docs/operations/database.md)

  # A frame that fails because the database is unavailable is answered with a
  # retryable `unavailable` error. Without a session yet (hello) the
  # connection closes with 1013 (try again later) instead.
  defp safe_handle_frame(frame, state) do
    handle_frame(frame, state)
  rescue
    error in DBConnection.ConnectionError ->
      Pressure.report(:protocol, error)
      type = if is_binary(frame["type"]), do: frame["type"]
      opts = [frame_type: type, retry_after_ms: Pressure.retry_after_ms()]
      unavailable = error("unavailable", "the database is unavailable, retry", opts)
      unavailable = with_client_id(unavailable, frame)

      case state.phase do
        :ready -> reply([unavailable], state)
        _ -> close(1013, "try again later", [unavailable], state)
      end
  end

  # A gap the feed cannot read now is not delivered: the next live activity
  # retries it, and the client may `sync` from the watermark in the error.
  defp live(activity, state) do
    {frames, feed} = Feed.live(state.feed, activity)
    reply(frames, %{state | feed: feed})
  rescue
    error in DBConnection.ConnectionError ->
      Pressure.report(:protocol, error)
      reply([replay_unavailable(state.feed.last_seq)], state)
  end

  # A replay that cannot read the database: the session continues live after
  # `head` and the client `sync`s from its watermark later.
  defp replay(feed, position, head) do
    Feed.replay(feed, position, head)
  rescue
    error in DBConnection.ConnectionError ->
      Pressure.report(:protocol, error)

      watermark =
        case position do
          nil -> 0
          {:seq, seq} -> seq
          _legacy -> nil
        end

      {[replay_unavailable(watermark)], Feed.seek(feed, head)}
  end

  # Like the replay, the open interrupts are best effort under database
  # pressure: the session starts without them (a later reconnect or the
  # replay of the interrupt frame itself renders them).
  defp pending(conversation_id) do
    Activities.open_interrupts(conversation_id)
  rescue
    error in DBConnection.ConnectionError ->
      Pressure.report(:protocol, error)
      []
  end

  defp replay_unavailable(watermark) do
    details = if is_integer(watermark), do: %{"watermark" => watermark}

    error("replay_unavailable", "the database is unavailable, sync from the watermark later",
      details: details,
      retry_after_ms: Pressure.retry_after_ms()
    )
  end

  ## Frames

  defp handle_frame(%{"type" => "hello"} = frame, %{phase: :awaiting_hello} = state),
    do: handshake(frame, %{state | protocol: string(frame["protocol"])})

  defp handle_frame(%{"type" => type}, %{phase: :awaiting_hello} = state) do
    reply([error("no_session", "send hello first", frame_type: type)], state)
  end

  defp handle_frame(_frame, %{phase: :awaiting_hello} = state) do
    reply([error("no_session", "send hello first")], state)
  end

  # A second hello is ignored (mekik/1 section 3.1).
  defp handle_frame(%{"type" => "hello"}, state), do: {:ok, state}

  defp handle_frame(%{"type" => "ping"} = frame, state) do
    reply([Frames.heartbeat(head_seq(state), frame["nonce"])], state)
  end

  defp handle_frame(%{"type" => "auth"} = frame, state), do: refresh_token(frame, state)

  # Section 10: everything else of a channel-scoped connection is enveloped.
  defp handle_frame(frame, %{mode: :channel} = state) do
    {frames, state} = ChannelSession.handle_frame(frame, state)
    reply(frames, state)
  end

  defp handle_frame(%{"type" => "sync"} = frame, state), do: sync(frame, state)

  # Token permissions (ADR-0059): typing needs `typing`, sends need `write`.
  defp handle_frame(%{"type" => "typing"}, state)
       when not is_map_key(state.permitted, "typing"),
       do: reply([insufficient_permission("typing", "typing")], state)

  defp handle_frame(%{"type" => "typing", "isTyping" => is_typing}, state)
       when is_boolean(is_typing) do
    typing =
      ConversationSignals.typing(
        state.typing,
        state.conversation_id,
        state.participant,
        is_typing
      )

    {:ok, %{state | typing: typing}}
  end

  defp handle_frame(%{"type" => "typing"}, state),
    do:
      reply(
        [error("bad_request", "typing needs a boolean isTyping", frame_type: "typing")],
        state
      )

  defp handle_frame(%{"type" => "read"} = frame, state) do
    case ConversationSignals.read(state.conversation_id, state.participant, frame["watermark"]) do
      {:ok, _read_seq} ->
        {:ok, state}

      {:error, :invalid_watermark} ->
        message = "read needs a watermark of at least 1"
        reply([error("invalid_watermark", message, frame_type: "read")], state)

      {:error, :not_found} ->
        reply(
          [error("conversation_not_found", "conversation not found", frame_type: "read")],
          state
        )
    end
  end

  # Section 9: frames only the bot answers go to the conversation's bot
  # channel, unchanged.
  defp handle_frame(%{"type" => type} = frame, state) when type in @bot_frames do
    conversation = Conversations.get_conversation(state.conversation_id)

    case BotRelay.forward(conversation, frame) do
      :ok ->
        {:ok, state}

      {:error, :bot_unavailable} ->
        message = "this conversation has no bot channel"

        reply(
          [error("bot_unavailable", message, frame_type: type) |> with_client_id(frame)],
          state
        )
    end
  end

  defp handle_frame(%{"type" => type} = frame, state) when is_binary(type) do
    case Send.kind(type) do
      kind when kind in [:text, :rich] and not is_map_key(state.permitted, "write") ->
        reply([insufficient_permission("write", type) |> with_client_id(frame)], state)

      kind when kind in [:text, :rich] ->
        send_message(frame, state)

      :reserved ->
        reply([error("bad_request", "#{type} is not a client frame", frame_type: type)], state)

      :unknown ->
        reply([error("bad_request", "unknown frame type")], state)
    end
  end

  defp handle_frame(_frame, state) do
    reply([error("bad_request", "a frame needs a string type")], state)
  end

  ## Handshake

  defp handshake(hello, state) do
    with :ok <- check_protocol(hello["protocol"]),
         {:ok, claims} <- authenticate(state.token || string(hello["token"])),
         :ok <- permit(claims, "read"),
         {:ok, channel} <- active_channel(claims),
         {:ok, scope} <- scope(claims, hello) do
      case scope do
        :channel -> start_channel_session(hello, claims, channel, state)
        {:conversation, conversation} -> start_session(hello, claims, conversation, state)
      end
    else
      {:error, :unsupported_protocol} ->
        frame = error("unsupported_protocol", "this server speaks #{Protocol.version()}")
        close(4400, "unsupported protocol", [frame], state)

      {:error, :unauthorized} ->
        close(4401, "unauthorized", [error("unauthorized", "missing or invalid token")], state)

      {:error, :token_revoked} ->
        close(4401, "token revoked", [error("token_revoked", "the token was revoked")], state)

      {:error, {:insufficient_permission, permission}} ->
        frame = insufficient_permission(permission, nil)
        close(4403, "insufficient permission", [frame], state)

      {:error, :channel_inactive} ->
        close(4403, "channel inactive", [error("channel_inactive", "channel is inactive")], state)

      {:error, :conversation_not_found} ->
        frame = error("conversation_not_found", "conversation not found")
        close(1008, "conversation not found", [frame], state)
    end
  end

  defp check_protocol(nil), do: :ok
  defp check_protocol("converger/1"), do: :ok
  defp check_protocol("mekik/1"), do: :ok
  defp check_protocol(_other), do: {:error, :unsupported_protocol}

  defp authenticate(nil), do: {:error, :unauthorized}

  defp authenticate(token) do
    case ConvergerToken.verify_token(token) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} when reason in [:token_revoked, :token_rotated] -> {:error, :token_revoked}
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  defp permitted(claims) do
    for permission <- ConvergerToken.permissions(),
        ConvergerToken.permitted?(claims, permission),
        into: %{},
        do: {permission, true}
  end

  defp permit(claims, permission) do
    if ConvergerToken.permitted?(claims, permission),
      do: :ok,
      else: {:error, {:insufficient_permission, permission}}
  end

  defp insufficient_permission(permission, frame_type) do
    error("insufficient_permission", "the token lacks the #{permission} permission",
      frame_type: frame_type,
      details: %{"required" => permission}
    )
  end

  defp active_channel(claims) do
    case Channels.get_active_channel(claims["channel_id"], claims["tenant_id"]) do
      {:ok, channel} -> {:ok, channel}
      _ -> {:error, :channel_inactive}
    end
  end

  # Section 10: a channel-scoped token (no conversation) follows the channel.
  defp scope(claims, hello) do
    if ChannelSession.channel_token?(claims) do
      {:ok, :channel}
    else
      with {:ok, conversation} <- resolve_conversation(claims, hello),
           do: {:ok, {:conversation, conversation}}
    end
  end

  defp start_channel_session(hello, claims, channel, state) do
    state = %{state | permitted: permitted(claims)}

    case ChannelSession.start(hello, claims, channel, state) do
      {:ok, {frames, state}} ->
        state = schedule_expiry(state, claims)
        reply(frames, state)

      {:error, :channel_type} ->
        message = "channel-scoped connections need a websocket channel"
        close(4403, "forbidden", [error("forbidden", message)], state)
    end
  end

  # Section 3.2: a conversation_id claim fixes the conversation; with a
  # channel-level token an asserted conversationId is adopted when it belongs
  # to the token's channel (and user), otherwise a new conversation starts.
  defp resolve_conversation(%{"conversation_id" => id} = claims, _hello) when is_binary(id) do
    channel_id = claims["channel_id"]

    case Conversations.get_conversation(id, claims["tenant_id"]) do
      %{channel_id: ^channel_id} = conversation ->
        {:ok, conversation}

      _ ->
        {:error, :conversation_not_found}
    end
  end

  defp resolve_conversation(claims, hello) do
    case adoptable(claims, hello["conversationId"]) do
      nil -> with :ok <- permit(claims, "write"), do: create_conversation(claims)
      conversation -> {:ok, conversation}
    end
  end

  defp adoptable(claims, asserted) when is_binary(asserted) do
    channel_id = claims["channel_id"]

    with {:ok, id} <- Ecto.UUID.cast(asserted),
         %{channel_id: ^channel_id} = conversation <-
           Conversations.get_conversation(id, claims["tenant_id"]),
         true <- owned_by?(conversation, claims["user_id"]) do
      conversation
    else
      _ -> nil
    end
  end

  defp adoptable(_claims, _asserted), do: nil

  defp owned_by?(_conversation, nil), do: true

  defp owned_by?(conversation, user_id) do
    conversation.metadata["user_id"] in [nil, user_id]
  end

  defp create_conversation(claims) do
    metadata =
      case claims["user_id"] do
        nil -> %{"source" => "converger"}
        user_id -> %{"source" => "converger", "user_id" => user_id}
      end

    case Conversations.create_conversation(%{
           "tenant_id" => claims["tenant_id"],
           "channel_id" => claims["channel_id"],
           "metadata" => metadata
         }) do
      {:ok, conversation} -> {:ok, conversation}
      {:error, _changeset} -> {:error, :conversation_not_found}
    end
  end

  defp start_session(hello, claims, conversation, state) do
    conversation_id = conversation.id
    user_id = user_id(claims, hello)

    # Subscribe before reading the head and the replay, so frames committed
    # meanwhile are held back in the mailbox and de-duplicated by the feed.
    Phoenix.PubSub.subscribe(Converger.PubSub, "conversation:#{conversation_id}")
    track(claims, conversation_id)

    participant = ConversationSignals.participant(claims)
    presence? = ConversationSignals.presence?(claims)
    ConversationSignals.subscribe(conversation_id, presence?)
    if presence?, do: ConversationSignals.track_presence(conversation_id, participant)

    head = Conversations.get_conversation(conversation_id).last_seq

    # A client whose asserted conversation was replaced resets to 0.
    position =
      if hello["conversationId"] in [nil, conversation_id],
        do: watermark_position(hello["watermark"]),
        else: nil

    state = %{
      state
      | phase: :ready,
        claims: claims,
        permitted: permitted(claims),
        conversation_id: conversation_id,
        user_id: user_id,
        participant: participant,
        feed: Feed.new(conversation_id, user_id)
    }

    state = schedule_expiry(state, claims)

    welcome =
      Frames.welcome(%{
        conversation_id: conversation_id,
        user_id: user_id,
        connection_id: state.connection_id,
        watermark: head,
        # Open interrupts, so a client whose watermark is past them (a
        # reloaded page) renders them again (mekik/1 section 3.2).
        pending: pending(conversation_id),
        expires_at: claims["exp"] * 1000,
        presence: presence?
      })

    # Who is already online, after the replay.
    presence =
      if presence?,
        do: ConversationSignals.presence_snapshot(conversation_id, participant),
        else: []

    case position do
      {:seq, seq} when seq > head ->
        message = "watermark #{seq} is above the head #{head}"
        feed = Feed.seek(state.feed, head)
        reply([welcome, error("invalid_watermark", message) | presence], %{state | feed: feed})

      position ->
        {frames, feed} = replay(state.feed, position, head)
        reply([welcome | frames] ++ presence, %{state | feed: feed})
    end
  end

  # A verified user_id claim wins; otherwise the asserted one is echoed
  # (informational only), or one is minted.
  defp user_id(%{"user_id" => user_id}, _hello) when is_binary(user_id) and user_id != "",
    do: user_id

  defp user_id(_claims, %{"userId" => user_id})
       when is_binary(user_id) and byte_size(user_id) in 1..256,
       do: user_id

  defp user_id(_claims, _hello), do: Protocol.random_id("user")

  # Wrong types are ignored as if absent (mekik/1), which replays from 0.
  defp watermark_position(value) do
    case Protocol.parse_watermark(value) do
      {:ok, position} -> position
      {:error, _} -> nil
    end
  end

  defp track(claims, conversation_id) do
    socket_id =
      claims
      |> Map.put("conversation_id", claims["conversation_id"] || conversation_id)
      |> ConvergerWeb.Sockets.converger_socket_id()

    if socket_id do
      Phoenix.PubSub.subscribe(Converger.PubSub, socket_id)

      ConvergerWeb.Sockets.track_id(socket_id, claims["channel_id"], %{
        tenant_id: claims["tenant_id"],
        conversation_id: conversation_id,
        transport: "converger/1"
      })
    end
  end

  ## Sending (section 7)

  defp send_message(frame, state) do
    with {:ok, client_id} <- Send.client_id(frame),
         {:ok, params} <- Send.message_params(frame, client_id),
         :ok <- rate_limit(state.claims) do
      params = Send.resolve_reply_to(params, frame, state.conversation_id)
      persist(params, client_id, state, frame["meta"])
    else
      {:error, code, message, opts} ->
        reply([error(code, message, [frame_type: frame["type"]] ++ opts)], state)
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

  defp persist(params, client_id, state, meta) do
    key = idempotency_key(state.user_id, client_id)

    case Activities.get_activity_by_idempotency_key(state.conversation_id, key) do
      nil ->
        # A turn with meta needs a key the bot side can match it by (section 9).
        key = key || meta_key(meta)
        relay_meta(state.conversation_id, key, meta)
        create(params, client_id, key, state)

      existing ->
        reply([Frames.ack(existing, client_id, true)], state)
    end
  end

  # Namespaced by sender, as the Phoenix binding's `postActivity` does, so a
  # clientId never collides with another sender's or a REST
  # X-Idempotency-Key, and a resend over any transport is recognised.
  defp idempotency_key(_sender, nil), do: nil
  defp idempotency_key(sender, client_id), do: Frames.client_key(sender, client_id)

  defp create(params, client_id, key, state) do
    system_attrs = %{
      "sender" => state.user_id,
      "tenant_id" => state.claims["tenant_id"],
      "conversation_id" => state.conversation_id,
      "idempotency_key" => key
    }

    opts = [client_id: client_id, frame_type: params["message_type"] || "text"]

    case store(params, system_attrs, state) do
      {:ok, activity} ->
        state = %{state | feed: Feed.own(state.feed, activity.seq)}

        if client_id,
          do: reply([Frames.ack(activity, client_id, false)], state),
          else: {:ok, state}

      {:error, :conversation_closed} ->
        reply([error("conversation_closed", "the conversation is closed", opts)], state)

      {:error, :inbound_not_supported} ->
        message = "the channel does not accept messages (mode outbound)"
        reply([error("forbidden", message, opts)], state)

      {:error, %Ecto.Changeset{} = changeset} ->
        details = Frames.changeset_details(changeset)

        frame =
          error("invalid_message", "the message failed validation", [details: details] ++ opts)

        reply([frame], state)

      {:error, reason} ->
        Logger.warning("Protocol send failed", reason: inspect(reason))
        reply([error("internal", "the message could not be accepted, retry", opts)], state)
    end
  end

  # mekik/1 per-turn context goes to the bot channel ahead of the turn, keyed
  # by the turn.s idempotency key (section 9); it is never stored.
  defp relay_meta(conversation_id, key, meta) when is_map(meta) and map_size(meta) > 0 do
    case Conversations.get_conversation(conversation_id) do
      nil -> :ok
      conversation -> BotRelay.turn_meta(conversation, key, meta)
    end
  end

  defp relay_meta(_conversation_id, _key, _meta), do: :ok

  defp meta_key(meta) when is_map(meta) and map_size(meta) > 0, do: Protocol.random_id("meta")
  defp meta_key(_meta), do: nil

  # On a `websocket` channel the connection is the channel's own transport:
  # the message is the channel's inbound message (Converger.Inbound, mode
  # checked), as on the Phoenix binding. Tokens of other channel types write
  # directly.
  defp store(params, system_attrs, state) do
    case Channels.get_active_channel(state.claims["channel_id"], state.claims["tenant_id"]) do
      {:ok, %{type: "websocket"} = channel} ->
        message = Map.merge(params, Map.take(system_attrs, ["sender", "idempotency_key"]))

        case Inbound.receive_message(channel, message,
               conversation_id: system_attrs["conversation_id"]
             ) do
          {tag, activity} when tag in [:created, :duplicate] -> {:ok, activity}
          {:rejected, changeset} -> {:error, changeset}
          {:error, _} = error -> error
        end

      _ ->
        Activities.create_client_activity(
          params,
          Map.put(system_attrs, "source_channel_id", state.claims["channel_id"])
        )
    end
  end

  ## sync, auth

  defp sync(frame, state) do
    head = Conversations.get_conversation(state.conversation_id).last_seq

    case Protocol.parse_watermark(frame["watermark"]) do
      {:ok, {:seq, seq}} when seq > head ->
        message = "watermark #{seq} is above the head #{head}"
        reply([error("invalid_watermark", message, frame_type: "sync")], state)

      {:ok, position} ->
        {frames, feed} = replay(state.feed, position || {:seq, 0}, head)
        reply(frames, %{state | feed: feed})

      {:error, _} ->
        reply([error("invalid_watermark", "invalid watermark", frame_type: "sync")], state)
    end
  end

  # Section 3.3: the new token must name the same tenant, channel,
  # conversation and user as the session's.
  defp refresh_token(frame, state) do
    with {:ok, claims} <- authenticate(string(frame["token"])),
         true <- same_identity?(claims, state.claims) do
      state = schedule_expiry(%{state | claims: claims}, claims)
      reply([Frames.token_refreshed(claims["exp"] * 1000)], state)
    else
      _ ->
        message = "the token does not match this session"
        reply([error("forbidden", message, frame_type: "auth")], state)
    end
  end

  # A refreshed token must not widen the session: same identity and
  # permissions.
  defp same_identity?(new, old) do
    Enum.all?(~w(tenant_id channel_id conversation_id user_id perms), &(new[&1] == old[&1]))
  end

  ## Helpers

  defp schedule_expiry(state, %{"exp" => exp}) when is_integer(exp) do
    if state.expiry_timer, do: Process.cancel_timer(state.expiry_timer)
    delay = max(exp * 1000 - System.system_time(:millisecond), 0)
    %{state | expiry_timer: Process.send_after(self(), :token_expired, delay)}
  end

  defp schedule_expiry(state, _claims), do: state

  defp schedule_tick(state) do
    interval = max(div(min(state.heartbeat_ms, state.idle_ms), 4), 10)
    Process.send_after(self(), :tick, interval)
  end

  defp error(code, message, opts \\ []), do: Frames.error(code, message, opts)

  defp with_client_id(%{"data" => data} = error_frame, frame) do
    client_id = frame["clientId"]

    if Protocol.client_id?(client_id),
      do: %{error_frame | "data" => Map.put(data, "clientId", client_id)},
      else: error_frame
  end

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  defp reply([], state), do: {:ok, state}

  defp reply(frames, state) do
    Converger.Telemetry.ws_frame("protocol", state.transport, :out, length(frames))
    {:push, frames, %{state | last_out: now()}}
  end

  defp close(code, reason, frames, state),
    do: {:close, %{code: code, reason: reason, retry_after_ms: nil}, frames, state}

  # 1012 (draining) and 4503 (slow consumer) carry a jittered reconnect delay.
  defp close_with_retry(code, reason, frames, state) do
    close = %{code: code, reason: reason, retry_after_ms: SocketGuard.retry_after_ms()}
    {:close, close, frames, state}
  end

  # A channel-scoped connection has no single conversation head.
  defp head_seq(%{mode: :channel}), do: nil
  defp head_seq(state), do: state.feed.last_seq

  defp now, do: System.monotonic_time(:millisecond)
end
