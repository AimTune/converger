defmodule ConvergerWeb.ConvergerChannel do
  use ConvergerWeb, :channel

  require Logger

  alias Converger.{Activities, RateLimit}
  alias Converger.ConvergerAPI.Watermark
  alias Converger.Pagination
  alias ConvergerWeb.ConvergerAPI.ActivityJSON
  alias ConvergerWeb.{ConversationSignals, SocketGuard}

  @impl true
  def join("converger:conversation:" <> conversation_id, payload, socket) do
    claims = socket.assigns.converger_claims

    if authorized?(conversation_id, claims) do
      watermark = payload["watermark"]

      socket =
        socket
        |> assign(:conversation_id, conversation_id)
        |> assign(:participant, ConversationSignals.participant(claims))
        |> assign(:presence?, ConversationSignals.presence?(claims))
        |> assign(:typing, ConversationSignals.new_typing())

      # Subscribe to the existing PubSub topic used by the pipeline, and to
      # the transient signals (typing, read receipts) of the conversation.
      ConvergerWeb.Endpoint.subscribe("conversation:#{conversation_id}")
      ConversationSignals.subscribe(conversation_id, socket.assigns.presence?)

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
    %{conversation_id: conversation_id, participant: participant, typing: typing} =
      socket.assigns

    typing = ConversationSignals.typing(typing, conversation_id, participant, is_typing)
    {:reply, :ok, assign(socket, :typing, typing)}
  end

  def handle_in("typing", _payload, socket), do: bad_request(socket)

  # `read {watermark}`: the connection's participant has read everything up
  # to `watermark`. The stored position never moves backwards.
  def handle_in("read", %{"watermark" => watermark}, socket) do
    %{conversation_id: conversation_id, participant: participant} = socket.assigns

    case ConversationSignals.read(conversation_id, participant, watermark) do
      {:ok, read_seq} -> {:reply, {:ok, %{watermark: read_seq}}, socket}
      {:error, :invalid_watermark} -> {:reply, {:error, %{reason: "invalid_watermark"}}, socket}
      {:error, :not_found} -> {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  def handle_in("read", _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_watermark"}}, socket}

  def handle_in(_event, _payload, socket), do: bad_request(socket)

  defp bad_request(socket), do: {:reply, {:error, %{reason: "bad_request"}}, socket}

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
      %{conversation_id: conversation_id, participant: participant} = socket.assigns
      ConversationSignals.track_presence(conversation_id, participant)

      conversation_id
      |> ConversationSignals.presence_snapshot(participant)
      |> Enum.each(&SocketGuard.push_ephemeral(socket, &1.type, &1))
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

  # Transient signals: delivery and read receipts, typing, presence
  # (ConversationSignals decides what this connection sees).
  def handle_info(%Phoenix.Socket.Broadcast{event: event, payload: payload}, socket)
      when event in ~w(delivery_status typing read presence_diff) do
    %{conversation_id: conversation_id, participant: participant} = socket.assigns

    event
    |> ConversationSignals.frames(payload, conversation_id, participant)
    |> Enum.each(fn
      {:reliable, frame} -> push(socket, frame.type, frame)
      {:ephemeral, frame} -> SocketGuard.push_ephemeral(socket, frame.type, frame)
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
    case socket.assigns do
      %{typing: typing, conversation_id: conversation_id, participant: participant} ->
        ConversationSignals.stop_typing(typing, conversation_id, participant)

      _ ->
        :ok
    end

    :ok
  end

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
