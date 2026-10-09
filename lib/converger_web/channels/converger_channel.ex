defmodule ConvergerWeb.ConvergerChannel do
  @moduledoc """
  Channel of the Converger API socket (`/socket/converger`).

  ## Topics

    * `converger:conversation:<conversation id>` - one conversation. Allowed
      for a token restricted to that conversation, and for a channel-scoped
      token (`scope: "channel"`) of either the conversation's own channel
      (**owned**) or a `websocket` channel that an enabled routing rule
      targets from the conversation's channel (**routed**). An unscoped
      channel-level token cannot join: it must get a conversation token first.
      An owned socket receives every activity of the conversation as it is
      committed (the `conversation:<id>` broadcast). A routed socket receives
      what the pipeline delivers to its channel, after that channel's
      middleware (`Converger.Channels.Adapters.WebSocket.conversation_topic/2`).
    * `converger:channel:<channel id>` - every delivery to a `websocket`
      channel, across conversations (an agent console). Requires a
      `scope: "channel"` token of that channel. Frames carry `conversation_id`.

  Every live and replayed activity is pushed as an `activitySet` frame. On a
  conversation topic the socket tracks the last `seq` it pushed: a frame at or
  below it is dropped (replay overlap, the same activity on two topics) and a
  frame above `last + 1` first pushes the missing range from the database
  (PubSub is at-most-once across nodes, and deliveries run concurrently).

  ## Client events

    * `postActivity` - send an activity. It goes through `Converger.Inbound`,
      so the socket's channel must be `inbound` or `duplex`. On a channel
      topic the payload names its `conversation_id`.
    * `ack` `{watermark}` - the client has received everything up to the
      watermark; marks the channel's pending deliveries `sent`
      (`Converger.Deliveries.acknowledge/3`). On a channel topic the payload
      names its `conversation_id`.
    * `typing`, `read` - conversation topics only.

  Unless the channel requires acks (`require_ack: true` in its config), a
  replay also marks the replayed activities' deliveries `sent`.
  """

  use ConvergerWeb, :channel

  require Logger

  alias Converger.{
    Activities,
    Channels,
    Conversations,
    Deliveries,
    Inbound,
    RateLimit,
    Receipts,
    RoutingRules
  }

  alias Converger.Channels.Adapters.WebSocket
  alias Converger.Channels.Signals
  alias Converger.ConvergerAPI.Watermark
  alias Converger.Pagination
  alias Converger.Pipeline.Middleware
  alias ConvergerWeb.ConvergerAPI.ActivityJSON
  alias ConvergerWeb.{ConvergerFrames, ConversationPresence, SocketGuard}

  # A client sends at most one typing frame per 2 s (protocol v1, section 11);
  # repeats of the same state inside the window are dropped silently.
  @typing_interval_ms 2_000

  # External typing indicators (WhatsApp) last ~25 s, so a connection that
  # keeps typing refreshes them at most this often.
  @typing_forward_interval_ms 20_000

  @impl true
  def join("converger:conversation:" <> conversation_id, payload, socket) do
    claims = socket.assigns.converger_claims

    with {:ok, channel} <- Channels.get_active_channel(claims["channel_id"], claims["tenant_id"]),
         {:ok, source, conversation} <- conversation_access(conversation_id, channel, claims) do
      # The head is read before subscribing: anything committed later arrives
      # live or is pushed by gap detection.
      socket =
        socket
        |> assign(:channel, channel)
        |> assign(:conversation_id, conversation.id)
        |> assign(:source, source)
        |> assign(:last_seq, conversation.last_seq)
        |> assign(:participant, participant(claims))
        |> assign(:presence?, presence?(channel, claims))
        |> assign(:typing, nil)
        |> assign(:typing_forwarded_at, nil)

      # Queued before subscribing, so every live frame is handled after the
      # replay and dropped when the replay already covered it.
      send(self(), {:after_join, payload["watermark"]})

      # The conversation topic carries delivery statuses for every socket and,
      # for an owned socket, the activities; a routed socket gets activities
      # from its channel's topic. Plus the transient signals (typing, read).
      ConvergerWeb.Endpoint.subscribe("conversation:#{conversation.id}")

      if source == :routed,
        do:
          ConvergerWeb.Endpoint.subscribe(
            WebSocket.conversation_topic(channel.id, conversation.id)
          )

      ConvergerWeb.Endpoint.subscribe(signals_topic(conversation.id))

      if socket.assigns.presence?,
        do: ConvergerWeb.Endpoint.subscribe(ConversationPresence.topic(conversation.id))

      {:ok, socket}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  def join("converger:channel:" <> channel_id, _payload, socket) do
    claims = socket.assigns.converger_claims

    with %{"scope" => "channel", "channel_id" => ^channel_id} <- claims,
         {:ok, %{type: "websocket"} = channel} <-
           Channels.get_active_channel(channel_id, claims["tenant_id"]) do
      send(self(), :after_join)
      ConvergerWeb.Endpoint.subscribe(WebSocket.channel_topic(channel_id))

      {:ok,
       socket
       |> assign(:channel, channel)
       |> assign(:conversation_id, nil)
       |> assign(:source, :channel)
       |> assign(:participant, participant(claims))}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_, _, _), do: {:error, %{reason: "invalid_topic"}}

  # `clientId` syntax of Protocol v1 (docs/protocol/v1.md, section 7).
  @client_id_format ~r/\A[A-Za-z0-9._:~-]{1,128}\z/

  # `postActivity`: send an activity over the socket, the WebSocket
  # equivalent of `POST /api/v1/converger/conversations/:id/activities`.
  #
  # The payload is a Direct Line-style activity (`type`, `text`,
  # `attachments`, `channelData`, `from.id`). The sender is the token's
  # verified `user_id` when it has one (a client-asserted `from.id` cannot
  # override it), otherwise `from.id`, otherwise `"user"`.
  #
  # The activity is received through `Converger.Inbound`, like an inbound
  # webhook of the socket's channel: the channel must be `inbound` or
  # `duplex`, and the pipeline (routing rules, middleware, deliveries) applies.
  #
  # An optional `clientId` makes a re-send safe: the activity is stored once
  # and a re-send with the same `clientId` (also after a reconnect) is
  # answered with the stored activity. The key is namespaced by sender
  # (`ws:<sender>:<clientId>`), so it cannot collide with REST
  # `X-Idempotency-Key`s or other senders.
  #
  # The reply carries the activity's `id`, `seq` and `watermark`, so the
  # client can match its send to the `activitySet` that follows.
  @impl true
  def handle_in("postActivity", payload, socket) when is_map(payload) do
    claims = socket.assigns.converger_claims
    sender = sender(claims, payload)

    with {:ok, conversation_id} <- target_conversation(socket, payload),
         {:ok, client_id} <- client_id(payload),
         :ok <- rate_limit(claims["tenant_id"]) do
      message =
        payload
        |> client_params()
        |> Map.merge(%{
          "sender" => sender,
          "idempotency_key" => client_id && "ws:#{sender}:#{client_id}"
        })

      socket.assigns.channel
      |> receive_message(message, conversation_id)
      |> reply_to_post(socket)
    else
      {:error, reply} -> {:reply, {:error, reply}, socket}
    end
  end

  def handle_in("postActivity", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_activity"}}, socket}
  end

  # `ack {watermark}`: the client received everything up to the watermark.
  def handle_in("ack", %{"watermark" => watermark} = payload, socket) do
    %{channel: channel} = socket.assigns

    with {:ok, conversation_id} <- ack_conversation(socket, payload),
         {:ok, seq} <- ack_seq(watermark) do
      count =
        if channel.type == "websocket",
          do: Deliveries.acknowledge(channel.id, conversation_id, seq),
          else: 0

      {:reply, {:ok, %{acknowledged: count}}, socket}
    else
      _ -> {:reply, {:error, %{reason: "invalid_ack"}}, socket}
    end
  end

  # --- Client frames ---

  # Typing and read receipts belong to one conversation.
  def handle_in(event, _payload, %{assigns: %{source: :channel}} = socket)
      when event in ["typing", "read"],
      do: bad_request(socket)

  # `typing {isTyping}`: relayed to the conversation's other connections and,
  # when the adapter supports it, to the external channel. Never stored.
  def handle_in("typing", %{"isTyping" => is_typing}, socket) when is_boolean(is_typing) do
    now = System.monotonic_time(:millisecond)

    socket =
      case socket.assigns.typing do
        {^is_typing, at} when now - at < @typing_interval_ms ->
          socket

        _ ->
          %{conversation_id: conversation_id, participant: participant} = socket.assigns

          ConvergerWeb.Endpoint.broadcast_from(
            self(),
            signals_topic(conversation_id),
            "typing",
            %{
              participant: participant,
              is_typing: is_typing
            }
          )

          socket
          |> assign(:typing, {is_typing, now})
          |> maybe_forward_typing(is_typing, now)
      end

    {:reply, :ok, socket}
  end

  def handle_in("typing", _payload, socket), do: bad_request(socket)

  # `read {watermark}`: the connection's participant has read everything up
  # to `watermark`. The stored position never moves backwards.
  def handle_in("read", %{"watermark" => watermark}, socket) do
    %{conversation_id: conversation_id, participant: participant} = socket.assigns

    with {:ok, watermark} <- read_watermark(watermark),
         %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id) do
      case Receipts.mark_read(conversation, participant.id, watermark) do
        {:ok, :advanced, read_seq} ->
          ConvergerWeb.Endpoint.broadcast(signals_topic(conversation_id), "read", %{
            up_to_seq: read_seq,
            by: participant,
            at: DateTime.utc_now()
          })

          Signals.forward_read(conversation_id, participant.id, read_seq)
          {:reply, {:ok, %{watermark: read_seq}}, socket}

        {:ok, :unchanged, read_seq} ->
          {:reply, {:ok, %{watermark: read_seq}}, socket}

        {:error, :invalid_watermark} ->
          {:reply, {:error, %{reason: "invalid_watermark"}}, socket}
      end
    else
      {:error, :invalid_watermark} -> {:reply, {:error, %{reason: "invalid_watermark"}}, socket}
      nil -> {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  def handle_in("read", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_watermark"}}, socket}

  # A malformed known event or an unknown event: answered, the channel stays joined.
  def handle_in(_event, _payload, socket), do: bad_request(socket)

  defp bad_request(socket), do: {:reply, {:error, %{reason: "bad_request"}}, socket}

  # The v1 integer seq, its decimal string form, or the opaque `seq:<n>`
  # watermark of an `activitySet` frame (the only form this binding's
  # activity frames expose).
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

  defp maybe_forward_typing(socket, false, _now), do: socket

  defp maybe_forward_typing(socket, true, now) do
    case socket.assigns.typing_forwarded_at do
      at when is_integer(at) and now - at < @typing_forward_interval_ms ->
        socket

      _ ->
        %{conversation_id: conversation_id, participant: participant} = socket.assigns
        Signals.forward_typing(conversation_id, participant.id, true)
        assign(socket, :typing_forwarded_at, now)
    end
  end

  defp sender(%{"user_id" => user_id}, _payload) when is_binary(user_id) and user_id != "",
    do: user_id

  defp sender(_claims, %{"from" => %{"id" => id}}) when is_binary(id) and id != "", do: id
  defp sender(_claims, _payload), do: "user"

  # Same mapping as the REST endpoint (ConvergerAPI.ActivityController).
  defp client_params(payload) do
    %{
      "type" => payload["type"] || "message",
      "text" => payload["text"],
      "attachments" => payload["attachments"] || [],
      "metadata" => payload["channelData"] || %{}
    }
  end

  defp client_id(payload) do
    case Map.get(payload, "clientId") do
      nil ->
        {:ok, nil}

      id when is_binary(id) ->
        if Regex.match?(@client_id_format, id),
          do: {:ok, id},
          else: client_id_error()

      _ ->
        client_id_error()
    end
  end

  defp client_id_error do
    {:error,
     %{
       reason: "invalid_activity",
       errors: %{clientId: ["must be 1 to 128 characters of A-Z a-z 0-9 . _ : ~ -"]}
     }}
  end

  # Shares the tenant's `activity_create` bucket with the REST endpoints.
  defp rate_limit(tenant_id) do
    case RateLimit.check(:activity_create, "tenant:#{tenant_id}", tenant: tenant_id) do
      {:allow, _count} ->
        :ok

      {:deny, retry_after_ms, _spec} ->
        {:error, %{reason: "rate_limited", retry_after_ms: retry_after_ms}}
    end
  end

  # For a `websocket` channel the socket is the channel's own transport, so
  # its messages are the channel's inbound messages (mode checked). A token of
  # another channel type (echo, webhook, ...) is a client of the conversation,
  # like the REST endpoint.
  defp receive_message(%{type: "websocket"} = channel, message, conversation_id),
    do: Inbound.receive_message(channel, message, conversation_id: conversation_id)

  defp receive_message(channel, message, conversation_id) do
    message
    |> Activities.create_client_activity(%{
      tenant_id: channel.tenant_id,
      conversation_id: conversation_id,
      sender: message["sender"],
      idempotency_key: message["idempotency_key"]
    })
    |> case do
      {:ok, activity} -> {:created, activity}
      {:error, %Ecto.Changeset{} = changeset} -> {:rejected, changeset}
      {:error, _} = error -> error
    end
  end

  defp target_conversation(%{assigns: %{source: :channel}} = socket, payload) do
    %{channel: channel, converger_claims: claims} = socket.assigns

    case conversation_access(payload["conversation_id"], channel, claims) do
      {:ok, _source, conversation} -> {:ok, conversation.id}
      :error -> {:error, %{reason: "unauthorized"}}
    end
  end

  defp target_conversation(socket, _payload), do: {:ok, socket.assigns.conversation_id}

  defp reply_to_post({tag, activity}, socket) when tag in [:created, :duplicate] do
    {:reply,
     {:ok, %{id: activity.id, seq: activity.seq, watermark: Watermark.encode(activity.seq)}},
     socket}
  end

  defp reply_to_post({:rejected, changeset}, socket),
    do: {:reply, {:error, %{reason: "invalid_activity", errors: errors(changeset)}}, socket}

  defp reply_to_post({:error, reason}, socket)
       when reason in [:conversation_closed, :inbound_not_supported, :not_found],
       do: {:reply, {:error, %{reason: to_string(reason)}}, socket}

  defp reply_to_post({:error, _reason}, socket),
    do: {:reply, {:error, %{reason: "invalid_activity"}}, socket}

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
      end)
    end)
  end

  defp ack_conversation(%{assigns: %{source: :channel}}, payload),
    do: Ecto.UUID.cast(payload["conversation_id"])

  defp ack_conversation(socket, _payload), do: {:ok, socket.assigns.conversation_id}

  defp ack_seq(seq) when is_integer(seq) and seq >= 0, do: {:ok, seq}

  defp ack_seq(watermark) when is_binary(watermark) do
    case Integer.parse(watermark) do
      {seq, ""} when seq >= 0 ->
        {:ok, seq}

      _ ->
        case Watermark.decode(watermark) do
          {:ok, {:seq, seq}} -> {:ok, seq}
          _ -> :error
        end
    end
  end

  defp ack_seq(_watermark), do: :error

  # --- Server pushes ---

  @impl true
  def handle_info(:after_join, socket) do
    channel = socket.assigns.channel

    ConvergerWeb.Sockets.track(socket, channel.id, %{
      tenant_id: channel.tenant_id,
      scope: "channel"
    })

    {:noreply, socket}
  end

  def handle_info({:after_join, watermark}, socket) do
    %{channel: channel, conversation_id: conversation_id} = socket.assigns

    ConvergerWeb.Sockets.track(socket, channel.id, %{
      tenant_id: channel.tenant_id,
      conversation_id: conversation_id
    })

    if socket.assigns.presence? do
      track_presence(socket)
      push_presence_snapshot(socket)
    end

    # Without a watermark the client starts live (no replay) from the current
    # head. Replay is capped at :ws_replay_limit activities (the oldest ones
    # after the watermark); when `has_more` is true the client fetches the
    # rest over GET /api/v1/converger/conversations/:id/activities?watermark=<frame watermark>
    # until `has_more` is false.
    socket =
      case Watermark.decode(watermark) do
        {:ok, {_, _} = position} -> replay(socket, position)
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "new_activity", payload: payload},
        %{assigns: %{source: :channel}} = socket
      ) do
    push(socket, "activitySet", %{
      conversation_id: payload.conversation_id,
      activities: [ActivityJSON.activity_data(payload)],
      watermark: Watermark.encode(payload.seq),
      has_more: false
    })

    {:noreply, socket}
  end

  # A routed socket takes activities from its channel's topic only (after the
  # channel's middleware), not the committed ones from the conversation topic.
  def handle_info(
        %Phoenix.Socket.Broadcast{event: "new_activity", topic: "conversation:" <> _},
        %{assigns: %{source: :routed}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "new_activity", payload: payload}, socket) do
    {:noreply, push_live(socket, payload)}
  end

  # Delivery progress of an activity towards a target channel. Every
  # connection of the conversation gets it, except identified end users who
  # did not send the activity.
  def handle_info(%Phoenix.Socket.Broadcast{event: "delivery_status", payload: payload}, socket) do
    if delivery_status_visible?(socket.assigns.participant, payload) do
      push(socket, "deliveryStatus", ConvergerFrames.delivery_status(payload))
    end

    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "typing", payload: payload}, socket) do
    if payload.participant.id != socket.assigns.participant.id do
      SocketGuard.push_ephemeral(
        socket,
        "typing",
        ConvergerFrames.typing(payload.is_typing, payload.participant)
      )
    end

    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "read", payload: payload}, socket) do
    if payload.by.id != socket.assigns.participant.id do
      push(
        socket,
        "deliveryStatus",
        ConvergerFrames.read_receipt(payload.up_to_seq, payload.by, payload.at)
      )
    end

    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}, socket) do
    own_id = socket.assigns.participant.id
    topic = ConversationPresence.topic(socket.assigns.conversation_id)
    now = DateTime.utc_now()

    (Map.keys(diff.joins) ++ Map.keys(diff.leaves))
    |> Enum.uniq()
    |> Enum.reject(&(&1 == own_id))
    |> Enum.each(fn id ->
      metas =
        case ConversationPresence.get_by_key(topic, id) do
          %{metas: metas} -> metas
          _ -> []
        end

      meta =
        List.first(metas) || List.first(get_in(diff, [:leaves, id, :metas]) || []) ||
          List.first(get_in(diff, [:joins, id, :metas]) || [])

      SocketGuard.push_ephemeral(
        socket,
        "presence",
        ConvergerFrames.presence(presence_participant(id, meta), length(metas), now)
      )
    end)

    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # A connection that closes while its participant is typing clears the
  # indicator for the others instead of leaving it to expire.
  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:typing] do
      {true, _at} ->
        ConvergerWeb.Endpoint.broadcast_from(
          self(),
          signals_topic(socket.assigns.conversation_id),
          "typing",
          %{participant: socket.assigns.participant, is_typing: false}
        )

      _ ->
        :ok
    end

    :ok
  end

  # --- Pushing activities ---

  defp push_live(%{assigns: %{last_seq: last}} = socket, %{seq: seq} = payload) do
    cond do
      seq == last + 1 ->
        push(socket, "activitySet", %{
          activities: [ActivityJSON.activity_data(payload)],
          watermark: Watermark.encode(seq),
          has_more: false
        })

        assign(socket, :last_seq, seq)

      # Already pushed: replay overlap or a duplicate broadcast.
      seq <= last ->
        socket

      # A gap: push the missing range (which includes this activity) from the database.
      true ->
        replay(socket, {:seq, last})
    end
  end

  defp replay(socket, position) do
    {activities, has_more} =
      Activities.page_activities_since(socket.assigns.conversation_id, position,
        limit: Pagination.config(:ws_replay_limit)
      )

    push_activities(socket, activities, has_more)
  end

  # One activitySet for activities read from the database (in seq order).
  defp push_activities(socket, [], _has_more), do: socket

  defp push_activities(socket, activities, has_more) do
    last_seq = List.last(activities).seq

    case Enum.flat_map(activities, &frame(socket, &1)) do
      [] ->
        :ok

      frames ->
        push(socket, "activitySet", %{
          activities: frames,
          watermark: Watermark.encode(last_seq),
          has_more: has_more
        })
    end

    acknowledge_replayed(socket, last_seq)
    assign(socket, :last_seq, last_seq)
  end

  # A routed socket sees activities as delivered to its channel: the
  # channel's middleware applies (a halted activity is not pushed).
  defp frame(%{assigns: %{source: :routed, channel: channel}}, activity) do
    case Middleware.run(activity, channel) do
      {:ok, transformed} -> [ActivityJSON.activity_data(transformed)]
      {:halt, _reason} -> []
    end
  end

  defp frame(_socket, activity), do: [ActivityJSON.activity_data(activity)]

  defp acknowledge_replayed(%{assigns: %{channel: channel, conversation_id: id}}, seq) do
    if channel.type == "websocket" and not WebSocket.require_ack?(channel),
      do: Deliveries.acknowledge(channel.id, id, seq)
  end

  # --- Participants and presence ---

  @doc """
  The participant identity of a connection, from its token claims: the
  token's `user_id`, or `"anonymous"` without one. A channel-scoped token
  (`scope: "channel"`, an agent console) has role `"agent"`; conversation
  tokens have role `"user"`.
  """
  def participant(%{"scope" => "channel"} = claims) do
    case claims["user_id"] do
      user_id when is_binary(user_id) and user_id != "" -> %{id: user_id, role: "agent"}
      _ -> %{id: "agent", role: "agent"}
    end
  end

  def participant(claims) do
    case claims["user_id"] do
      user_id when is_binary(user_id) and user_id != "" -> %{id: user_id, role: "user"}
      _ -> %{id: "anonymous", role: "user"}
    end
  end

  # The socket's channel decides (config key "presence"):
  #   "identified" (default) - every connection with a user_id
  #   "all"                  - anonymous end users too (one "anonymous" participant)
  #   "off"                  - no presence frames at all
  defp presence?(channel, claims) do
    case (channel.config || %{})["presence"] do
      "off" -> false
      "all" -> true
      _ -> participant(claims).id != "anonymous"
    end
  end

  defp track_presence(socket) do
    %{conversation_id: conversation_id, participant: participant} = socket.assigns

    ConversationPresence.track(
      self(),
      ConversationPresence.topic(conversation_id),
      participant.id,
      %{role: participant.role, online_at: System.system_time(:millisecond)}
    )
  end

  # Who is already online when this connection joins.
  defp push_presence_snapshot(socket) do
    own_id = socket.assigns.participant.id
    now = DateTime.utc_now()

    socket.assigns.conversation_id
    |> ConversationPresence.topic()
    |> ConversationPresence.list()
    |> Enum.reject(fn {id, _} -> id == own_id end)
    |> Enum.each(fn {id, %{metas: metas}} ->
      SocketGuard.push_ephemeral(
        socket,
        "presence",
        ConvergerFrames.presence(presence_participant(id, List.first(metas)), length(metas), now)
      )
    end)
  end

  defp presence_participant(id, %{role: role}), do: %{id: id, role: role}
  defp presence_participant(id, _meta), do: %{id: id}

  defp delivery_status_visible?(%{role: "user", id: id}, payload) when id != "anonymous",
    do: Map.get(payload, :sender) == id

  defp delivery_status_visible?(_participant, _payload), do: true

  defp signals_topic(conversation_id), do: "conversation:#{conversation_id}:signals"

  # --- Authorization ---

  # {:ok, :owned | :routed, conversation} when the token may follow the
  # conversation. Only conversation tokens and channel-scoped tokens may join:
  # an unscoped channel-level token (from POST /tokens/generate, typically
  # held by an end-user widget) must first create or resume a conversation,
  # which returns a conversation token; letting it join any conversation of
  # the channel would expose other users' conversations.
  defp conversation_access(conversation_id, channel, claims) do
    restricted = claims["conversation_id"]

    with {:ok, conversation_id} <- Ecto.UUID.cast(conversation_id),
         true <- is_binary(restricted) or claims["scope"] == "channel",
         true <- is_nil(restricted) or restricted == conversation_id,
         %Conversations.Conversation{} = conversation <-
           Conversations.get_conversation(conversation_id, channel.tenant_id) do
      cond do
        conversation.channel_id == channel.id ->
          {:ok, :owned, conversation}

        channel.type == "websocket" and
            RoutingRules.routes_to?(conversation.channel_id, channel.id, channel.tenant_id) ->
          {:ok, :routed, conversation}

        # A token issued for this one conversation.
        is_binary(restricted) ->
          {:ok, :owned, conversation}

        true ->
          :error
      end
    else
      _ -> :error
    end
  end
end
