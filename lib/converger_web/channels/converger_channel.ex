defmodule ConvergerWeb.ConvergerChannel do
  use ConvergerWeb, :channel

  require Logger

  alias Converger.{Activities, Channels, Conversations, RateLimit, Receipts}
  alias Converger.Channels.Signals
  alias Converger.ConvergerAPI.Watermark
  alias Converger.Pagination
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

    if authorized?(conversation_id, claims) do
      watermark = payload["watermark"]

      socket =
        socket
        |> assign(:conversation_id, conversation_id)
        |> assign(:participant, participant(claims))
        |> assign(:presence?, presence?(claims))
        |> assign(:typing, nil)
        |> assign(:typing_forwarded_at, nil)

      # Subscribe to the existing PubSub topic used by the pipeline, and to
      # the transient signals (typing, read receipts) of the conversation.
      ConvergerWeb.Endpoint.subscribe("conversation:#{conversation_id}")
      ConvergerWeb.Endpoint.subscribe(signals_topic(conversation_id))

      if socket.assigns.presence?,
        do: ConvergerWeb.Endpoint.subscribe(ConversationPresence.topic(conversation_id))

      send(self(), {:after_join, watermark})
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
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

    with {:ok, client_id} <- client_id(payload),
         :ok <- rate_limit(claims["tenant_id"]) do
      payload
      |> client_params()
      |> Activities.create_client_activity(%{
        tenant_id: claims["tenant_id"],
        conversation_id: socket.assigns.conversation_id,
        sender: sender,
        idempotency_key: client_id && "ws:#{sender}:#{client_id}"
      })
      |> reply_to_post(socket)
    else
      {:error, reply} -> {:reply, {:error, reply}, socket}
    end
  end

  def handle_in("postActivity", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_activity"}}, socket}
  end

  # --- Client frames ---

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

  defp reply_to_post({:ok, activity}, socket) do
    {:reply,
     {:ok, %{id: activity.id, seq: activity.seq, watermark: Watermark.encode(activity.seq)}},
     socket}
  end

  defp reply_to_post({:error, :conversation_closed}, socket),
    do: {:reply, {:error, %{reason: "conversation_closed"}}, socket}

  defp reply_to_post({:error, %Ecto.Changeset{} = changeset}, socket),
    do: {:reply, {:error, %{reason: "invalid_activity", errors: errors(changeset)}}, socket}

  defp reply_to_post({:error, _reason}, socket),
    do: {:reply, {:error, %{reason: "invalid_activity"}}, socket}

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
      end)
    end)
  end

  # --- Server pushes ---

  @impl true
  def handle_info({:after_join, watermark}, socket) do
    conversation_id = socket.assigns.conversation_id
    claims = socket.assigns.converger_claims

    ConvergerWeb.Sockets.track(socket, claims["channel_id"], %{
      tenant_id: claims["tenant_id"],
      conversation_id: conversation_id
    })

    if socket.assigns.presence? do
      track_presence(socket)
      push_presence_snapshot(socket)
    end

    # Without a watermark the client starts live (no replay). Replay is capped
    # at :ws_replay_limit activities (the oldest ones after the watermark);
    # when `has_more` is true the client fetches the rest over
    # GET /api/v1/converger/conversations/:id/activities?watermark=<frame watermark>
    # until `has_more` is false, de-duplicating by activity id against live frames.
    {activities, has_more} =
      case Watermark.decode(watermark) do
        {:ok, nil} ->
          {[], false}

        {:ok, position} ->
          Activities.page_activities_since(conversation_id, position,
            limit: Pagination.config(:ws_replay_limit)
          )

        {:error, _} ->
          {[], false}
      end

    if activities != [] do
      new_watermark = activities |> List.last() |> Map.get(:seq) |> Watermark.encode()

      push(socket, "activitySet", %{
        activities: Enum.map(activities, &ActivityJSON.activity_data/1),
        watermark: new_watermark,
        has_more: has_more
      })
    end

    {:noreply, socket}
  end

  # Handle PubSub broadcasts from the pipeline (conversation:{id} topic)
  def handle_info(%Phoenix.Socket.Broadcast{event: "new_activity", payload: payload}, socket) do
    watermark = Watermark.encode(payload.seq)

    activity_set = %{
      activities: [ActivityJSON.activity_data(payload)],
      watermark: watermark,
      has_more: false
    }

    push(socket, "activitySet", activity_set)
    {:noreply, socket}
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

  # --- Participants and presence ---

  @doc """
  The participant identity of a connection, from its token claims: the
  token's `user_id`, or `"anonymous"` without one.

  Only conversation tokens can join (see `authorized?/2`), so every
  participant has role `"user"` for now; agent consoles get their own role
  with channel-scoped sockets (#64/#67).
  """
  def participant(claims) do
    case claims["user_id"] do
      user_id when is_binary(user_id) and user_id != "" -> %{id: user_id, role: "user"}
      _ -> %{id: "anonymous", role: "user"}
    end
  end

  # The conversation's channel decides (config key "presence"):
  #   "identified" (default) - every connection with a user_id
  #   "all"                  - anonymous end users too (one "anonymous" participant)
  #   "off"                  - no presence frames at all
  defp presence?(claims) do
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

  defp authorized?(conversation_id, %{"conversation_id" => claim_cid})
       when is_binary(claim_cid) do
    conversation_id == claim_cid
  end

  # Only conversation-bound tokens may join. A channel-level token (from
  # POST /tokens/generate, typically held by an end-user widget) must first
  # create or resume a conversation (POST/GET /conversations), which returns a
  # conversation token; letting it join any conversation of the channel would
  # expose other users' conversations. Channel-wide agent sockets get an
  # explicit `scope: "channel"` claim in Protocol v1 (#64/#67).
  defp authorized?(_, _), do: false
end
