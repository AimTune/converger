defmodule ConvergerWeb.ProtocolSocket do
  @moduledoc """
  The native Converger Protocol v1 WebSocket endpoint (docs/protocol/v1.md,
  section 2.1): `GET /socket/converger/v1`, raw v1 frames with no Phoenix
  Channels framing, one frame per WebSocket message.

  This is a `WebSock` handler, upgraded to by `ConvergerWeb.ProtocolSocketController`
  (which also negotiates the subprotocol, and with it the encoding). One
  process serves one connection to one conversation:

      client -> hello
      server -> welcome, replay (seq > hello.watermark), live frames
      client -> text {clientId}      server -> ack {clientId, id, seq}
      client -> sync {watermark}     server -> replay
      client -> ping                 server -> heartbeat
      client -> auth {token}         server -> tokenRefreshed

  Ordering, de-duplication, gap filling and the echo rule are
  `ConvergerWeb.Protocol.Feed`; frames are `ConvergerWeb.Protocol.Frames`.

  Close codes (section 12.3): 4400 unsupported protocol, 4401 unauthorized or
  token expired, 4403 channel deactivated or forced disconnect, 4408 idle
  timeout, 1008 when the conversation cannot be resolved.
  """

  @behaviour WebSock

  require Logger

  alias Converger.{Activities, Channels, Conversations, RateLimit}
  alias Converger.Auth.ConvergerToken
  alias ConvergerWeb.Protocol
  alias ConvergerWeb.Protocol.{Codec, Feed, Frames}

  # Frames a client sends that need a bot channel (mekik relay, #64).
  @bot_frames ~w(resume genui_event client_tools client_skills abort survey regenerate edit)

  # Client frames specified by v1 whose server side ships with #25: accepted
  # and ignored until then, so clients can already send them.
  @ignored_frames ~w(typing read)

  # Reserved frame types that are not client frames (section 5.5).
  @reserved ~w(welcome resume genui_event client_tools client_skills abort tool_call skill
               skills genui genui_components interrupt interrupt_resolved run error typing
               survey regenerate edit ack deliveryStatus presence conversationUpdate
               endOfConversation event heartbeat ping read sync auth tokenRefreshed
               replayTruncated subscribe unsubscribe subscribed unsubscribed message
               activity activitySet frame hello)

  @message_type ~r/^[a-z][a-z0-9_-]{0,63}$/

  ## WebSock callbacks

  @impl WebSock
  def init(opts) do
    now = now()

    state = %{
      phase: :awaiting_hello,
      encoding: Keyword.fetch!(opts, :encoding),
      token: Keyword.get(opts, :token),
      connection_id: Protocol.random_id("conn"),
      heartbeat_ms: Protocol.config(:heartbeat_interval_ms),
      idle_ms: Protocol.config(:idle_timeout_ms),
      max_frame_bytes: Protocol.config(:max_frame_bytes),
      last_in: now,
      last_out: now,
      claims: nil,
      conversation_id: nil,
      user_id: nil,
      feed: nil,
      expiry_timer: nil
    }

    schedule_tick(state)
    {:ok, state}
  end

  @impl WebSock
  def handle_in({data, opcode: opcode}, state) do
    state = %{state | last_in: now()}

    if byte_size(data) > state.max_frame_bytes do
      reply(
        [Frames.error("payload_too_large", "frame exceeds #{state.max_frame_bytes} bytes")],
        state
      )
    else
      case Codec.decode(data, opcode, state.encoding) do
        {:ok, frame} -> handle_frame(frame, state)
        {:error, message} -> reply([Frames.error("bad_request", message)], state)
      end
    end
  end

  @impl WebSock
  def handle_control({_data, opcode: _opcode}, state), do: {:ok, %{state | last_in: now()}}

  @impl WebSock
  def handle_info(%Phoenix.Socket.Broadcast{event: "new_activity", payload: activity}, state)
      when state.phase == :ready do
    {frames, feed} = Feed.live(state.feed, activity)
    reply(frames, %{state | feed: feed})
  end

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
        reply([Frames.heartbeat(state.feed.last_seq)], state)

      true ->
        {:ok, state}
    end
  end

  def handle_info(:token_expired, state) do
    close(4401, "token expired", [error("token_expired", "token expired, refresh it")], state)
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state), do: :ok

  ## Frames

  defp handle_frame(%{"type" => "hello"} = frame, %{phase: :awaiting_hello} = state),
    do: handshake(frame, state)

  defp handle_frame(%{"type" => type}, %{phase: :awaiting_hello} = state) do
    reply([error("no_session", "send hello first", frame_type: type)], state)
  end

  defp handle_frame(_frame, %{phase: :awaiting_hello} = state) do
    reply([error("no_session", "send hello first")], state)
  end

  # A second hello is ignored (mekik/1 section 3.1).
  defp handle_frame(%{"type" => "hello"}, state), do: {:ok, state}

  defp handle_frame(%{"type" => "ping"} = frame, state) do
    reply([Frames.heartbeat(state.feed.last_seq, frame["nonce"])], state)
  end

  defp handle_frame(%{"type" => "sync"} = frame, state), do: sync(frame, state)
  defp handle_frame(%{"type" => "auth"} = frame, state), do: refresh_token(frame, state)
  defp handle_frame(%{"type" => type}, state) when type in @ignored_frames, do: {:ok, state}

  defp handle_frame(%{"type" => type}, state) when type in @bot_frames do
    message = "this conversation has no bot channel"
    reply([error("bot_unavailable", message, frame_type: type)], state)
  end

  defp handle_frame(%{"type" => type} = frame, state) when is_binary(type) do
    cond do
      type == "text" ->
        send_message(frame, state)

      type in @reserved ->
        reply([error("bad_request", "#{type} is not a client frame", frame_type: type)], state)

      Regex.match?(@message_type, type) ->
        # Rich message types (image, card, ...) are stored from #28 on.
        message = "message type #{type} is not supported yet"

        reply(
          [error("invalid_message", message, frame_type: type) |> with_client_id(frame)],
          state
        )

      true ->
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
         {:ok, _channel} <- active_channel(claims),
         {:ok, conversation} <- resolve_conversation(claims, hello) do
      start_session(hello, claims, conversation, state)
    else
      {:error, :unsupported_protocol} ->
        frame = error("unsupported_protocol", "this server speaks #{Protocol.version()}")
        close(4400, "unsupported protocol", [frame], state)

      {:error, :unauthorized} ->
        close(4401, "unauthorized", [error("unauthorized", "missing or invalid token")], state)

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
      {:error, _reason} -> {:error, :unauthorized}
    end
  end

  defp active_channel(claims) do
    case Channels.get_active_channel(claims["channel_id"], claims["tenant_id"]) do
      {:ok, channel} -> {:ok, channel}
      _ -> {:error, :channel_inactive}
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
      nil -> create_conversation(claims)
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
        conversation_id: conversation_id,
        user_id: user_id,
        feed: Feed.new(conversation_id, user_id)
    }

    state = schedule_expiry(state, claims)

    welcome =
      Frames.welcome(%{
        conversation_id: conversation_id,
        user_id: user_id,
        connection_id: state.connection_id,
        watermark: head,
        expires_at: claims["exp"] * 1000
      })

    case position do
      {:seq, seq} when seq > head ->
        message = "watermark #{seq} is above the head #{head}"
        feed = Feed.seek(state.feed, head)
        reply([welcome, error("invalid_watermark", message)], %{state | feed: feed})

      position ->
        {frames, feed} = Feed.replay(state.feed, position, head)
        reply([welcome | frames], %{state | feed: feed})
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
    with {:ok, client_id} <- client_id(frame),
         {:ok, params} <- message_params(frame, client_id),
         :ok <- rate_limit(state.claims) do
      persist(params, client_id, state)
    else
      {:error, code, message, opts} ->
        reply([error(code, message, [frame_type: "text"] ++ opts)], state)
    end
  end

  # clientId wins; a mekik/1 `id` is used when it has the clientId syntax.
  defp client_id(%{"clientId" => client_id}) when client_id != nil do
    if Protocol.client_id?(client_id),
      do: {:ok, client_id},
      else: {:error, "bad_request", "invalid clientId", []}
  end

  defp client_id(%{"id" => id}) do
    if Protocol.client_id?(id), do: {:ok, id}, else: {:ok, nil}
  end

  defp client_id(_frame), do: {:ok, nil}

  defp message_params(%{"data" => %{"text" => text} = data} = frame, client_id)
       when is_binary(text) do
    attachments = Map.get(data, "attachments") || []
    metadata = Map.get(frame, "metadata") || %{}

    cond do
      not is_list(attachments) ->
        {:error, "bad_request", "data.attachments must be an array", [client_id: client_id]}

      not is_map(metadata) ->
        {:error, "bad_request", "metadata must be an object", [client_id: client_id]}

      true ->
        {:ok,
         %{
           "type" => "message",
           "text" => text,
           "attachments" => attachments,
           "metadata" => metadata
         }}
    end
  end

  defp message_params(_frame, client_id) do
    {:error, "bad_request", "a text frame needs data.text", [client_id: client_id]}
  end

  defp rate_limit(%{"tenant_id" => tenant_id}) do
    case RateLimit.check(:activity_create, "tenant:#{tenant_id}", tenant: tenant_id) do
      {:allow, _count} ->
        :ok

      {:deny, retry_after_ms, _spec} ->
        {:error, "rate_limited", "too many messages", [retry_after_ms: retry_after_ms]}
    end
  end

  defp persist(params, client_id, state) do
    case Activities.get_activity_by_idempotency_key(state.conversation_id, client_id) do
      nil ->
        create(params, client_id, state)

      %{sender: sender} = existing when sender == state.user_id ->
        reply([Frames.ack(existing, client_id, true)], state)

      _someone_else ->
        message = "clientId was already used by another sender"

        reply(
          [error("invalid_message", message, client_id: client_id, frame_type: "text")],
          state
        )
    end
  end

  defp create(params, client_id, state) do
    system_attrs = %{
      "sender" => state.user_id,
      "tenant_id" => state.claims["tenant_id"],
      "conversation_id" => state.conversation_id,
      "idempotency_key" => client_id
    }

    opts = [client_id: client_id, frame_type: "text"]

    case Activities.create_client_activity(params, system_attrs) do
      {:ok, activity} ->
        state = %{state | feed: Feed.own(state.feed, activity.seq)}

        if client_id,
          do: reply([Frames.ack(activity, client_id, false)], state),
          else: {:ok, state}

      {:error, :conversation_closed} ->
        reply([error("conversation_closed", "the conversation is closed", opts)], state)

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

  ## sync, auth

  defp sync(frame, state) do
    head = Conversations.get_conversation(state.conversation_id).last_seq

    case Protocol.parse_watermark(frame["watermark"]) do
      {:ok, {:seq, seq}} when seq > head ->
        message = "watermark #{seq} is above the head #{head}"
        reply([error("invalid_watermark", message, frame_type: "sync")], state)

      {:ok, position} ->
        {frames, feed} = Feed.replay(state.feed, position || {:seq, 0}, head)
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

  defp same_identity?(new, old) do
    Enum.all?(~w(tenant_id channel_id conversation_id user_id), &(new[&1] == old[&1]))
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
    {:push, Enum.map(frames, &Codec.encode(&1, state.encoding)), %{state | last_out: now()}}
  end

  defp close(code, reason, frames, state) do
    {:stop, :normal, {code, reason}, Enum.map(frames, &Codec.encode(&1, state.encoding)), state}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
